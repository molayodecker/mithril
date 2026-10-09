defmodule Mithril.DirectBookings do
  @moduledoc """
  Customer booking reads and writes for Instaclean Direct.

  Pricing is delegated to the same PostgreSQL `compute_booking_pricing` function
  used by the legacy web/mobile clients. Direct never accepts a client-computed
  amount or customer id.
  """

  require Logger

  alias Mithril.Repo

  @default_timezone "Africa/Accra"
  # Paystack plan intervals. Hourly and legacy bi-weekly stay unbookable.
  @bookable_recurrence_intervals ~w(daily weekly monthly quarterly annually)
  @property_types ~w(residential vacant_home office commercial airbnb_turnover post_construction)

  def list_services do
    # `service_types.duration` is a display string like "2 hours", so it cannot
    # be coalesced with numeric hour columns.
    case Repo.query("""
         SELECT jsonb_build_object(
           'id', id,
           'name', name,
           'category', category::text,
           'description', description,
           'features', COALESCE(to_jsonb(features), '[]'::jsonb),
           'priceGhs', price,
           'minimumDurationHours', COALESCE(minimum_duration_hours, 2),
           'maximumDurationHours', COALESCE(maximum_duration_hours, 12),
           'durationIncrementHours', COALESCE(duration_increment_hours, 0.5),
           'specialtySlug', specialty_slug,
           'weight', COALESCE(weight, 0)
         )
         FROM public.service_types
         WHERE active = true
         ORDER BY COALESCE(weight, 0) ASC, name ASC
         """) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  def list_categories do
    case Repo.query("""
         SELECT jsonb_build_object(
           'id', sc.id,
           'name', sc.name,
           'icon', sc.icon,
           'slug', sc.slug,
           'weight', COALESCE(sc.weight, 0),
           'description', sc.description,
           'imageUrl', sc.image_url,
           'iconScale', sc.icon_scale
         )
         FROM public.service_categories sc
         WHERE (
           NOT EXISTS (
             SELECT 1
             FROM public.service_types st
             WHERE st.category_id = sc.id
           )
           OR EXISTS (
             SELECT 1
             FROM public.service_types st
             WHERE st.category_id = sc.id
               AND st.active = true
           )
         )
         AND (
           CASE COALESCE(sc.slug, '')
             WHEN 'caregiving' THEN public.is_care_pet_catalog_visible()
             WHEN 'pet_care' THEN public.is_care_pet_catalog_visible()
             WHEN 'airbnb' THEN public.is_airbnb_catalog_visible()
             WHEN 'quick_tasks' THEN public.is_quick_tasks_catalog_visible()
             WHEN 'cooks' THEN public.is_cooks_catalog_visible()
             WHEN 'drivers' THEN public.is_drivers_catalog_visible()
             ELSE true
           END
         )
         ORDER BY COALESCE(sc.weight, 0) ASC, sc.name ASC
         """) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  def list_cleaners(service_id) do
    with {:ok, service_id} <- positive_integer(service_id),
         {:ok, service} <- service_details(service_id) do
      case Repo.query(
             """
             SELECT jsonb_build_object(
               'userId', cd.user_id,
               'name', COALESCE(
                 NULLIF(btrim(p.fullname), ''),
                 NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
                 'Instaclean professional'
               ),
               'avatarUrl', p.avatar_url,
               'rating', cd.rating,
               'completedJobs', cd.completed_jobs,
               'hourlyRateGhs', cd.hourly_rate
             )
             FROM public.cleaner_data cd
             LEFT JOIN public.profiles p ON p.id = cd.user_id
             WHERE cd.verified = true
               AND cd.status = 'active'
               AND cd.hourly_rate IS NOT NULL
               AND cd.hourly_rate > 0
               AND $1::text = ANY(COALESCE(cd.specialties, ARRAY[]::text[]))
             ORDER BY COALESCE(cd.rating, 0) DESC,
                      COALESCE(cd.completed_jobs, 0) DESC
             LIMIT 100
             """,
             [service.specialty_slug]
           ) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_service}
      {:error, reason} -> {:error, reason}
    end
  end

  def preview_price(params) when is_map(params) do
    with {:ok, input} <- validate_pricing_input(params),
         {:ok, service} <- service_details(input.service_id),
         :ok <- cleaner_eligible(input.cleaner_id, service.specialty_slug),
         {:ok, pricing} <- compute_pricing(input) do
      {:ok, pricing}
    end
  end

  def create_customer_booking(user_id, params) when is_map(params) do
    if client_bookings_enabled?() do
      create_booking(user_id, params)
    else
      {:error, :client_bookings_disabled}
    end
  end

  def create_booking(user_id, params) when is_map(params) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, input} <- validate_create_input(params) do
      Repo.transaction(fn ->
        with :ok <- lock_booking_idempotency(customer_id, input.idempotency_key),
             {:ok, existing} <- find_idempotent_booking(customer_id, input.idempotency_key) do
          if existing do
            existing
          else
            with {:ok, service} <- service_details(input.service_id),
                 :ok <- cleaner_eligible(input.cleaner_id, service.specialty_slug),
                 {:ok, pricing} <- compute_pricing(input),
                 :ok <- validate_timeslot(input, pricing),
                 :ok <- validate_cleaner_availability(input, pricing, nil),
                 :ok <- ensure_customer_profile(customer_id),
                 {:ok, booking_id, subscription_id} <-
                   insert_booking(customer_id, input, pricing, service.name) do
              booking_result(
                booking_id,
                "pending",
                "pending",
                pricing["finalAmountMinor"],
                pricing["currency"],
                subscription_id
              )
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def replace_unpaid_booking(user_id, booking_id, params) when is_map(params) do
    if client_bookings_enabled?() do
      with {:ok, customer_id} <- dump_uuid(user_id),
           {:ok, bid} <- dump_uuid(booking_id),
           {:ok, input} <- validate_create_input(params),
           :ok <- require_replacement_idempotency_key(input) do
        replacement_input = %{
          input
          | idempotency_key: replacement_idempotency_key(bid, input.idempotency_key)
        }

        Repo.transaction(fn ->
          with {:ok, original} <- lock_unpaid_replacement_booking(customer_id, bid),
               :ok <- lock_booking_idempotency(customer_id, replacement_input.idempotency_key),
               {:ok, existing} <-
                 find_idempotent_booking(customer_id, replacement_input.idempotency_key),
               {:ok, path} <- replacement_path(original, existing),
               {:ok, result} <-
                 execute_unpaid_replacement(
                   path,
                   customer_id,
                   bid,
                   merge_replacement_visit_details(replacement_input, original, params),
                   existing
                 ) do
            result
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> normalize_transaction()
      else
        :error -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :client_bookings_disabled}
    end
  end

  defp require_replacement_idempotency_key(%{idempotency_key: key})
       when is_binary(key) and byte_size(key) > 0,
       do: :ok

  defp require_replacement_idempotency_key(_input), do: {:error, :invalid_idempotency_key}

  defp replacement_idempotency_key(booking_id, key) do
    booking_scope = Base.encode16(booking_id, case: :lower)
    digest = key |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
    "replace:#{booking_scope}:#{digest}"
  end

  defp lock_unpaid_replacement_booking(customer_id, booking_id) do
    case Repo.query(
           """
           SELECT id::text, status::text, payment_status::text, subscription_id, reference,
                  booking_for_self, site_contact_name, site_contact_phone,
                  site_contact_relationship, property_type, occupant_present,
                  requires_key_or_access_code, access_instructions, customer_contact_phone
           FROM public.bookings
           WHERE id = $1 AND customer_id = $2
           FOR UPDATE
           """,
           [booking_id, customer_id]
         ) do
      {:ok,
       %{
         rows: [
           [
             id,
             status,
             payment_status,
             subscription_id,
             reference,
             booking_for_self,
             site_contact_name,
             site_contact_phone,
             site_contact_relationship,
             property_type,
             occupant_present,
             requires_key_or_access_code,
             access_instructions,
             customer_contact_phone
           ]
         ]
       }} ->
        {:ok,
         %{
           id: id,
           status: status,
           payment_status: payment_status,
           subscription_id: subscription_id,
           reference: reference,
           visit: %{
             booking_for_self: booking_for_self,
             site_contact_name: site_contact_name,
             site_contact_phone: site_contact_phone,
             site_contact_relationship: site_contact_relationship,
             property_type: property_type,
             occupant_present: occupant_present,
             requires_key_or_access_code: requires_key_or_access_code,
             access_instructions: access_instructions,
             customer_contact_phone: customer_contact_phone
           }
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  # A schedule/cleaner edit must not erase the original on-site contact or access notes.
  # Explicit values, including nil/false, are respected when supplied by the client.
  defp merge_replacement_visit_details(input, original, params) do
    mapping = %{
      "bookingForSelf" => :booking_for_self,
      "siteContactName" => :site_contact_name,
      "siteContactPhone" => :site_contact_phone,
      "siteContactRelationship" => :site_contact_relationship,
      "propertyType" => :property_type,
      "occupantPresent" => :occupant_present,
      "requiresKeyOrAccessCode" => :requires_key_or_access_code,
      "accessInstructions" => :access_instructions,
      "customerContactPhone" => :customer_contact_phone
    }

    Enum.reduce(mapping, input, fn {key, field}, acc ->
      if Map.has_key?(params, key) do
        acc
      else
        Map.put(acc, field, original.visit[field])
      end
    end)
  end

  defp replacement_path(original, existing) do
    cond do
      not is_nil(existing) and existing.id == original.id ->
        {:error, :payment_conflict}

      original.status == "cancelled" and reusable_replacement?(existing) ->
        {:ok, :already_replaced}

      paid_payment_status?(original.payment_status) ->
        {:error, :already_paid}

      not is_nil(original.subscription_id) ->
        {:error, :not_cancellable}

      original.status not in ["pending", "confirmed"] ->
        {:error, :not_cancellable}

      not is_nil(existing) and not reusable_replacement?(existing) ->
        {:error, :payment_conflict}

      true ->
        {:ok, :replace}
    end
  end

  defp execute_unpaid_replacement(:already_replaced, _customer_id, _booking_id, _input, existing),
    do: {:ok, existing}

  defp execute_unpaid_replacement(:replace, customer_id, booking_id, input, existing) do
    with :ok <- ensure_no_active_payment_attempts(booking_id),
         :ok <- cancel_original_for_replacement(customer_id, booking_id) do
      if reusable_replacement?(existing) do
        {:ok, existing}
      else
        create_booking_locked(customer_id, input)
      end
    end
  end

  defp ensure_no_active_payment_attempts(booking_id) do
    case Repo.query(
           """
           SELECT EXISTS(
             SELECT 1
             FROM public.payment_attempts
             WHERE booking_id = $1
               AND status IN ('initializing', 'ready')
           )
           """,
           [booking_id]
         ) do
      {:ok, %{rows: [[false]]}} -> :ok
      {:ok, %{rows: [[true]]}} -> {:error, :payment_in_progress}
      {:error, error} -> database_error(error)
    end
  end

  defp cancel_original_for_replacement(customer_id, booking_id) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET status = 'cancelled',
               cancelled_at = now(),
               cancellation_reason = 'Replaced while updating this unpaid booking',
               cancellation_reason_code = 'customer_edit_replaced',
               reference = NULL,
               updated_at = now()
           WHERE id = $1
             AND customer_id = $2
             AND subscription_id IS NULL
             AND status::text = ANY($3::text[])
             AND (payment_status IS NULL OR payment_status::text = ANY($4::text[]))
           RETURNING id
           """,
           [booking_id, customer_id, ["pending", "confirmed"], ["pending", "failed"]]
         ) do
      {:ok, %{rows: [[_id]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :cancel_conflict}
      {:error, error} -> database_error(error)
    end
  end

  defp create_booking_locked(customer_id, input) do
    with {:ok, service} <- service_details(input.service_id),
         :ok <- cleaner_eligible(input.cleaner_id, service.specialty_slug),
         {:ok, pricing} <- compute_pricing(input),
         :ok <- validate_timeslot(input, pricing),
         :ok <- validate_cleaner_availability(input, pricing, nil),
         :ok <- ensure_customer_profile(customer_id),
         {:ok, booking_id, subscription_id} <-
           insert_booking(customer_id, input, pricing, service.name) do
      {:ok,
       booking_result(
         booking_id,
         "pending",
         "pending",
         pricing["finalAmountMinor"],
         pricing["currency"],
         subscription_id
       )}
    end
  end

  defp reusable_replacement?(nil), do: false

  defp reusable_replacement?(replacement) do
    replacement.status not in ["cancelled", "completed"]
  end

  defp paid_payment_status?(status) when is_binary(status) do
    String.downcase(status) in ["paid", "succeeded", "refunded", "partially_refunded"]
  end

  defp paid_payment_status?(_), do: false

  def list_bookings(user_id) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT #{booking_json_select()}
             FROM public.bookings b
             JOIN public.service_types st ON st.id = b.service_id
             LEFT JOIN public.profiles p ON p.id = b.cleaner_id
             WHERE b.customer_id = $1
             ORDER BY b.scheduled_date DESC NULLS LAST,
                      b.scheduled_time DESC NULLS LAST,
                      b.created_at DESC
             LIMIT 100
             """,
             [customer_id]
           ) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def get_booking(user_id, booking_id) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT #{booking_json_select()}
             FROM public.bookings b
             JOIN public.service_types st ON st.id = b.service_id
             LEFT JOIN public.profiles p ON p.id = b.cleaner_id
             WHERE b.id = $1 AND b.customer_id = $2
             LIMIT 1
             """,
             [bid, customer_id]
           ) do
      case result.rows do
        [[booking]] -> {:ok, booking}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def reschedule(user_id, booking_id, params) when is_map(params) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, input} <- validate_reschedule_input(params) do
      Repo.transaction(fn ->
        with {:ok, booking} <- lock_reschedule_booking(customer_id, bid),
             {:ok, path} <- reschedule_path(booking),
             schedule <- merge_reschedule_schedule(path, booking, input),
             :ok <- ensure_future_schedule(schedule),
             {:ok, pricing} <- reschedule_pricing(path, booking, schedule),
             :ok <- validate_timeslot(schedule, pricing),
             :ok <- validate_cleaner_availability(schedule, pricing, bid),
             :ok <- apply_reschedule(path, booking, schedule, pricing, customer_id) do
          booking.id
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction()
      |> case do
        {:ok, _id} -> get_booking(user_id, booking_id)
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp booking_json_select do
    """
    jsonb_build_object(
      'id', b.id,
      'status', b.status,
      'paymentStatus', b.payment_status,
      'serviceId', b.service_id,
      'serviceName', st.name,
      'cleanerId', b.cleaner_id,
      'cleanerName', COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        'Instaclean professional'
      ),
      'scheduledDate', b.scheduled_date,
      'scheduledTime', b.scheduled_time,
      'durationHours', b.duration_hours,
      'address', b.address,
      'amountMinor', COALESCE(b.final_amount_minor, b.total_price),
      'currency', COALESCE(b.currency, 'GHS')
    )
    """
  end

  defp compute_pricing(input) do
    # Live Postgres has two compute_booking_pricing overloads with overlapping
    # defaults. Pass the extra-task arguments so PostgreSQL can pick one.
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'currency', p.currency,
             'pricingVersion', p.pricing_version,
             'durationHours', p.duration_hours,
             'workRateGhsPerHour', p.work_rate_ghs_per_hour,
             'subtotalLaborMajor', p.subtotal_labor_major,
             'platformFeeMajor', p.platform_fee_major,
             'bookingCoverMajor', p.booking_cover_major,
             'coreAmountMinor', p.core_amount_minor,
             'sameDaySurchargeMinor', p.same_day_surcharge_minor,
             'weekendSurchargeMinor', p.weekend_surcharge_minor,
             'recurringDiscountMinor', p.recurring_discount_minor,
             'finalAmountMinor', p.final_amount_minor,
             'isSameDay', p.is_same_day,
             'isWeekend', p.is_weekend,
             'suppliesOption', p.supplies_option,
             'suppliesAllowanceMinor', p.supplies_allowance_minor,
             'cleanerEarningsMinor', p.cleaner_earnings_minor,
             'recurringAmountMinor', p.recurring_amount_minor,
             'firstChargeAmountMinor', p.first_charge_amount_minor,
             'discountRateBps', p.discount_rate_bps
           )
           FROM public.compute_booking_pricing(
             p_service_id => $1::integer,
             p_duration_hours_raw => $2::numeric,
             p_scheduled_date => $3::date,
             p_service_timezone => $4::text,
             p_recurrence_interval => $6::text,
             p_is_recurring => $7::boolean,
             p_include_booking_cover => true,
             p_supplies_option => 'customer_provided'::text,
             p_cleaner_id => $5::uuid,
             p_extra_task_ids => NULL,
             p_service_duration_option_id => NULL,
             p_visit_duration_hours => NULL,
             p_cleaning_scan_id => NULL
           ) p
           """,
           [
             input.service_id,
             decimal_hours(input.duration_hours),
             input.scheduled_date,
             input.timezone,
             input.cleaner_id,
             Map.get(input, :recurrence_interval),
             is_binary(Map.get(input, :recurrence_interval))
           ]
         ) do
      {:ok, %{rows: [[pricing]]}} ->
        {:ok, pricing}

      {:ok, %{rows: []}} ->
        {:error, :pricing_unavailable}

      {:error, error} ->
        Logger.warning("Direct booking pricing failed: #{inspect(error)}")
        {:error, :pricing_unavailable}
    end
  end

  defp service_details(service_id) do
    case Repo.query(
           """
           SELECT name, specialty_slug
           FROM public.service_types
           WHERE id = $1 AND active = true
           LIMIT 1
           """,
           [service_id]
         ) do
      {:ok, %{rows: [[name, specialty_slug]]}}
      when is_binary(specialty_slug) and specialty_slug != "" ->
        {:ok, %{name: name, specialty_slug: specialty_slug}}

      {:ok, %{rows: _}} ->
        {:error, :invalid_service}

      {:error, error} ->
        database_error(error)
    end
  end

  defp cleaner_eligible(cleaner_id, specialty_slug) do
    case Repo.query(
           """
           SELECT EXISTS(
             SELECT 1
             FROM public.cleaner_data cd
             WHERE cd.user_id = $1::uuid
               AND cd.verified = true
               AND cd.status = 'active'
               AND cd.hourly_rate IS NOT NULL
               AND cd.hourly_rate > 0
               AND $2::text = ANY(COALESCE(cd.specialties, ARRAY[]::text[]))
           )
           """,
           [cleaner_id, specialty_slug]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :cleaner_unavailable}
      {:error, error} -> database_error(error)
    end
  end

  defp validate_timeslot(input, pricing) do
    duration_hours = pricing["durationHours"] || input.duration_hours

    case Repo.query(
           """
           SELECT public.validate_booking_timeslot_24h(
             $1::text,
             $2::numeric,
             $3::date,
             $4::text
           )
           """,
           [
             format_hhmm(input.scheduled_time),
             decimal_hours(duration_hours),
             input.scheduled_date,
             input.timezone
           ]
         ) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      {:ok, %{rows: [[false]]}} ->
        {:error, :invalid_timeslot}

      {:error, error} ->
        Logger.warning("Direct booking timeslot validation failed: #{inspect(error)}")
        {:error, :database_unavailable}
    end
  end

  defp validate_cleaner_availability(input, pricing, exclude_booking_id) do
    if is_nil(input.cleaner_id) do
      :ok
    else
      validate_assigned_cleaner_availability(input, pricing, exclude_booking_id)
    end
  end

  defp validate_assigned_cleaner_availability(input, pricing, exclude_booking_id) do
    duration_hours = pricing["durationHours"] || input.duration_hours

    case Repo.query(
           """
           SELECT
             EXISTS(
               SELECT 1
               FROM public.cleaner_availability_exceptions cae
               WHERE cae.cleaner_id = $1::uuid
                 AND cae.exception_date = $2::date
             ),
             public.cleaner_has_booking_conflict(
               $1::uuid,
               (($2::date + $3::time) AT TIME ZONE $5::text),
               (($2::date + $3::time) AT TIME ZONE $5::text)
                 + make_interval(secs => ($4::numeric * 3600)::double precision),
               $6::uuid
             )
           """,
           [
             input.cleaner_id,
             input.scheduled_date,
             input.scheduled_time,
             decimal_hours(duration_hours),
             input.timezone,
             exclude_booking_id
           ]
         ) do
      {:ok, %{rows: [[false, false]]}} ->
        :ok

      {:ok, %{rows: [[true, _]]}} ->
        {:error, :cleaner_unavailable}

      {:ok, %{rows: [[_, true]]}} ->
        {:error, :cleaner_unavailable}

      {:error, error} ->
        Logger.warning("Direct cleaner availability validation failed: #{inspect(error)}")
        {:error, :database_unavailable}
    end
  end

  defp lock_booking_idempotency(_customer_id, nil), do: :ok

  defp lock_booking_idempotency(customer_id, idempotency_key) do
    customer_key = Base.encode16(customer_id, case: :lower)
    lock_key = "direct-booking:#{customer_key}:#{idempotency_key}"

    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [lock_key]) do
      {:ok, _} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp find_idempotent_booking(_customer_id, nil), do: {:ok, nil}

  defp find_idempotent_booking(customer_id, idempotency_key) do
    case Repo.query(
           """
           SELECT id::text,
                  status::text,
                  payment_status::text,
                  COALESCE(final_amount_minor, total_price)::bigint,
                  COALESCE(currency, 'GHS'),
                  subscription_id::text
           FROM public.bookings
           WHERE customer_id = $1
             AND idempotency_key = $2
           LIMIT 1
           """,
           [customer_id, idempotency_key]
         ) do
      {:ok, %{rows: [[id, status, payment_status, amount_minor, currency, subscription_id]]}} ->
        {:ok, booking_result(id, status, payment_status, amount_minor, currency, subscription_id)}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, error} ->
        database_error(error)
    end
  end

  defp ensure_customer_profile(customer_id) do
    case Repo.query(
           """
           INSERT INTO public.profiles (id, user_id)
           VALUES ($1, $1)
           ON CONFLICT (id) DO NOTHING
           """,
           [customer_id]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp booking_result(id, status, payment_status, amount_minor, currency, subscription_id) do
    result = %{
      id: id,
      status: status,
      paymentStatus: payment_status,
      amountMinor: amount_minor,
      currency: currency || "GHS"
    }

    if is_binary(subscription_id) and subscription_id != "" do
      Map.put(result, :subscriptionId, subscription_id)
    else
      result
    end
  end

  defp maybe_insert_subscription(_customer_id, %{recurrence_interval: interval}, _pricing)
       when interval in [nil, ""],
       do: {:ok, nil}

  defp maybe_insert_subscription(customer_id, %{recurrence_interval: interval} = input, pricing)
       when interval in @bookable_recurrence_intervals do
    recurring_minor = positive_minor(pricing["recurringAmountMinor"])
    first_minor = positive_minor(pricing["firstChargeAmountMinor"] || pricing["finalAmountMinor"])

    if is_nil(recurring_minor) or is_nil(first_minor) do
      {:error, :pricing_unavailable}
    else
      insert_pending_subscription(customer_id, input, pricing, recurring_minor, first_minor)
    end
  end

  defp insert_pending_subscription(customer_id, input, pricing, recurring_minor, first_minor) do
    case Repo.query(
           """
           INSERT INTO public.subscriptions (
             customer_id,
             cleaner_id,
             service_id,
             address,
             duration_hours,
             recurrence_interval,
             amount,
             recurring_amount_minor,
             first_charge_amount_minor,
             pricing_version,
             currency,
             discount_type,
             discount_rate_bps,
             status,
             next_occurrence_date,
             recurrence_anchor_date,
             scheduled_time,
             special_instructions,
             paystack_plan_interval,
             billing_mode
           ) VALUES (
             $1, $2, $3, $4, $5::numeric, $6, $7, $7, $8, $9, $10,
             $6, $11, 'pending', $12::date, $12::date, $13::time, NULLIF($14::text, ''),
             $6, 'paystack_plan'
           )
           RETURNING id::text
           """,
           [
             customer_id,
             input.cleaner_id,
             input.service_id,
             input.address,
             decimal_hours(pricing["durationHours"] || input.duration_hours),
             input.recurrence_interval,
             recurring_minor,
             first_minor,
             pricing["pricingVersion"],
             pricing["currency"] || "GHS",
             non_negative_integer(pricing["discountRateBps"]),
             input.scheduled_date,
             input.scheduled_time,
             input.special_instructions || ""
           ]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:error, error} -> database_error(error)
    end
  end

  defp insert_booking(customer_id, input, pricing, service_name) do
    with {:ok, subscription_id} <- maybe_insert_subscription(customer_id, input, pricing),
         {:ok, booking_id} <-
           insert_booking_row(customer_id, input, pricing, service_name, subscription_id) do
      {:ok, booking_id, subscription_id}
    end
  end

  defp insert_booking_row(customer_id, input, pricing, service_name, subscription_id) do
    case Repo.query(
           """
           INSERT INTO public.bookings (
             customer_id,
             cleaner_id,
             service_id,
             title,
             scheduled_date,
             scheduled_time,
             duration_hours,
             duration_final,
             address,
             special_instructions,
             total_price,
             final_amount_minor,
             core_amount_minor,
             same_day_surcharge_minor,
             weekend_surcharge_minor,
             recurring_discount_minor,
             is_same_day,
             is_weekend,
             pricing_version,
             currency,
             platform_fee,
             tax_amount,
             booking_cover,
             booking_cover_amount,
             work_rate_ghs_per_hour,
             supplies_option,
             supplies_allowance_minor,
             cleaner_earnings_minor,
             status,
             payment_status,
             timezone,
             idempotency_key,
             subscription_id,
             recurrence_interval,
             booking_for_self,
             site_contact_name,
             site_contact_phone,
             site_contact_relationship,
             property_type,
             occupant_present,
             requires_key_or_access_code,
             access_instructions,
             customer_contact_phone
           ) VALUES (
             $1, $2, $3, $4, $5::date, $6::time, $7, $7, $8,
             NULLIF($9::text, ''), $10::numeric, $11::integer, $12::integer,
             $13::integer, $14::integer, $15::integer,
             $16, $17, $18, $19, $20, 0, true, $21, $22, $23,
             $24::integer, $25::integer, 'pending', 'pending', $26, $27,
             $28::uuid, NULLIF($29::text, ''),
             $30, NULLIF($31::text, ''), NULLIF($32::text, ''), NULLIF($33::text, ''),
             NULLIF($34::text, ''), $35, $36, NULLIF($37::text, ''), NULLIF($38::text, '')
           )
           RETURNING id::text
           """,
           [
             customer_id,
             input.cleaner_id,
             input.service_id,
             service_name,
             input.scheduled_date,
             input.scheduled_time,
             decimal_hours(pricing["durationHours"] || input.duration_hours),
             input.address,
             input.special_instructions || "",
             pricing["finalAmountMinor"],
             pricing["finalAmountMinor"],
             pricing["coreAmountMinor"],
             pricing["sameDaySurchargeMinor"],
             pricing["weekendSurchargeMinor"],
             pricing["recurringDiscountMinor"],
             pricing["isSameDay"],
             pricing["isWeekend"],
             pricing["pricingVersion"],
             pricing["currency"] || "GHS",
             pricing["platformFeeMajor"],
             pricing["bookingCoverMajor"],
             pricing["workRateGhsPerHour"],
             pricing["suppliesOption"] || "customer_provided",
             pricing["suppliesAllowanceMinor"] || 0,
             pricing["cleanerEarningsMinor"],
             input.timezone,
             input.idempotency_key,
             dump_optional_uuid(subscription_id),
             Map.get(input, :recurrence_interval),
             Map.get(input, :booking_for_self, true),
             blank_to_nil(Map.get(input, :site_contact_name)),
             blank_to_nil(Map.get(input, :site_contact_phone)),
             blank_to_nil(Map.get(input, :site_contact_relationship)),
             blank_to_nil(Map.get(input, :property_type)),
             Map.get(input, :occupant_present),
             Map.get(input, :requires_key_or_access_code, false),
             blank_to_nil(Map.get(input, :access_instructions)),
             blank_to_nil(Map.get(input, :customer_contact_phone))
           ]
         ) do
      {:ok, %{rows: [[id]]}} ->
        {:ok, id}

      {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} ->
        {:error, :cleaner_unavailable}

      {:error, error} ->
        database_error(error)
    end
  end

  defp lock_reschedule_booking(customer_id, booking_id) do
    case Repo.query(
           """
           SELECT
             id::text,
             status,
             payment_status,
             subscription_id,
             cleaner_id,
             service_id,
             scheduled_date,
             scheduled_time,
             duration_hours,
             COALESCE(final_amount_minor, total_price) AS amount_minor,
             COALESCE(
               NULLIF(btrim(to_jsonb(b)->>'timezone_name'), ''),
               NULLIF(btrim(to_jsonb(b)->>'timezone'), ''),
               'Africa/Accra'
             ) AS timezone
           FROM public.bookings b
           WHERE id = $1 AND customer_id = $2
           FOR UPDATE
           """,
           [booking_id, customer_id]
         ) do
      {:ok, %{rows: [row]}} ->
        {:ok, hydrate_reschedule_booking(row)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp hydrate_reschedule_booking([
         id,
         status,
         payment_status,
         subscription_id,
         cleaner_id,
         service_id,
         scheduled_date,
         scheduled_time,
         duration_hours,
         amount_minor,
         timezone
       ]) do
    %{
      id: id,
      status: status,
      payment_status: payment_status,
      subscription_id: subscription_id,
      cleaner_id: cleaner_id,
      service_id: service_id,
      scheduled_date: scheduled_date,
      scheduled_time: scheduled_time,
      duration_hours: duration_hours,
      amount_minor: amount_minor,
      timezone: timezone || @default_timezone
    }
  end

  defp reschedule_path(booking) do
    status = String.downcase(to_string(booking.status || ""))
    payment_status = String.downcase(to_string(booking.payment_status || ""))

    cond do
      not is_nil(booking.subscription_id) ->
        {:error,
         {:not_reschedulable,
          "This booking belongs to a subscription. Change the schedule from your subscription settings."}}

      visit_passed?(booking) ->
        {:error,
         {:not_reschedulable, "This visit has already passed and can no longer be rescheduled."}}

      payment_status == "paid" and status in ~w(confirmed scheduled) ->
        {:ok, :paid}

      status in ~w(pending confirmed) and payment_status in ~w(pending failed) ->
        {:ok, :unpaid}

      status in ~w(cancelled completed en_route arrived in_progress) ->
        {:error,
         {:not_reschedulable, "This booking can no longer be rescheduled in its current status."}}

      true ->
        {:error, {:not_reschedulable, "This booking can no longer be rescheduled."}}
    end
  end

  defp visit_passed?(booking) do
    case scheduled_at(booking.scheduled_date, booking.scheduled_time, booking.timezone) do
      %DateTime{} = at -> DateTime.compare(at, DateTime.utc_now()) != :gt
      _ -> false
    end
  end

  defp merge_reschedule_schedule(path, booking, input) do
    duration_hours =
      case path do
        :paid -> booking.duration_hours
        :unpaid -> input.duration_hours || booking.duration_hours
      end

    %{
      cleaner_id: booking.cleaner_id,
      service_id: booking.service_id,
      scheduled_date: input.scheduled_date,
      scheduled_time: input.scheduled_time,
      duration_hours: duration_hours,
      timezone: input.timezone || booking.timezone
    }
  end

  defp ensure_future_schedule(schedule) do
    case scheduled_at(schedule.scheduled_date, schedule.scheduled_time, schedule.timezone) do
      %DateTime{} = at ->
        if DateTime.compare(at, DateTime.utc_now()) == :gt do
          :ok
        else
          {:error,
           {:past_schedule, "Cannot reschedule to a past time. Please select a future time."}}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp reschedule_pricing(:paid, booking, _schedule) do
    {:ok, %{"durationHours" => booking.duration_hours}}
  end

  defp reschedule_pricing(:unpaid, _booking, schedule) do
    compute_pricing(schedule)
  end

  defp apply_reschedule(:paid, booking, schedule, _pricing, customer_id) do
    update_reschedule_schedule(booking, schedule, customer_id, :paid)
  end

  defp apply_reschedule(:unpaid, booking, schedule, pricing, customer_id) do
    with :ok <- update_reschedule_schedule(booking, schedule, customer_id, :unpaid),
         :ok <- maybe_invalidate_repriced_checkout(booking, pricing) do
      update_unpaid_pricing(booking.id, pricing)
    end
  end

  defp maybe_invalidate_repriced_checkout(booking, pricing) do
    if amount_minor(booking.amount_minor) != amount_minor(pricing["finalAmountMinor"]) do
      case Repo.query(
             """
             WITH retired AS (
               UPDATE public.payment_attempts
               SET status = 'failed',
                   failure_reason = 'Booking repriced during reschedule',
                   failed_at = COALESCE(failed_at, now()),
                   updated_at = now()
               WHERE booking_id = $1::uuid
                 AND status IN ('initializing', 'ready')
               RETURNING id
             )
             UPDATE public.bookings
             SET reference = NULL,
                 updated_at = now()
             WHERE id = $1::uuid
               AND payment_status IN ('pending', 'failed')
             RETURNING id
             """,
             [dump!(booking.id)]
           ) do
        {:ok, %{rows: [[_id]]}} -> :ok
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, error} -> database_error(error)
      end
    else
      :ok
    end
  end

  defp update_reschedule_schedule(booking, schedule, customer_id, path) do
    {status_filter, payment_filter} =
      case path do
        :paid -> {~w(confirmed scheduled), ~w(paid)}
        :unpaid -> {~w(pending confirmed), ~w(pending failed)}
      end

    # status is the booking_status enum. Comparing it to text[] is 42883.
    case Repo.query(
           """
           UPDATE public.bookings
           SET scheduled_date = $2,
               scheduled_time = $3,
               duration_hours = $4,
               duration_final = $4,
               timezone = $5,
               timezone_name = $5,
               customer_reminder_sent_at = #{clear_reminder("customer_reminder_sent_at")},
               customer_reminder_claimed_at = #{clear_reminder("customer_reminder_claimed_at")},
               customer_reminder_7d_sent_at = #{clear_reminder("customer_reminder_7d_sent_at")},
               customer_reminder_7d_claimed_at = #{clear_reminder("customer_reminder_7d_claimed_at")},
               customer_reminder_5d_sent_at = #{clear_reminder("customer_reminder_5d_sent_at")},
               customer_reminder_5d_claimed_at = #{clear_reminder("customer_reminder_5d_claimed_at")},
               customer_reminder_48h_sent_at = #{clear_reminder("customer_reminder_48h_sent_at")},
               customer_reminder_48h_claimed_at = #{clear_reminder("customer_reminder_48h_claimed_at")},
               customer_reminder_morning_sent_at = #{clear_reminder("customer_reminder_morning_sent_at")},
               customer_reminder_morning_claimed_at = #{clear_reminder("customer_reminder_morning_claimed_at")},
               cleaner_reminder_sent_at = #{clear_reminder("cleaner_reminder_sent_at")},
               cleaner_reminder_claimed_at = #{clear_reminder("cleaner_reminder_claimed_at")},
               updated_at = now()
           WHERE id = $1
             AND customer_id = $6
             AND status::text = ANY($7::text[])
             AND payment_status = ANY($8::text[])
             AND subscription_id IS NULL
           RETURNING id
           """,
           [
             dump!(booking.id),
             schedule.scheduled_date,
             schedule.scheduled_time,
             decimal_hours(schedule.duration_hours),
             schedule.timezone,
             customer_id,
             status_filter,
             payment_filter
           ]
         ) do
      {:ok, %{rows: [[_id]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        {:error, {:not_reschedulable, "This booking can no longer be rescheduled."}}

      {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} ->
        {:error, :cleaner_unavailable}

      {:error, error} ->
        database_error(error)
    end
  end

  defp update_unpaid_pricing(booking_id, pricing) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET total_price = $2::numeric,
               final_amount_minor = $3::integer,
               core_amount_minor = $4::integer,
               same_day_surcharge_minor = $5::integer,
               weekend_surcharge_minor = $6::integer,
               recurring_discount_minor = $7::integer,
               is_same_day = $8,
               is_weekend = $9,
               pricing_version = $10,
               platform_fee = $11,
               booking_cover = true,
               booking_cover_amount = $12,
               work_rate_ghs_per_hour = $13,
               supplies_option = $14,
               supplies_allowance_minor = $15::integer,
               cleaner_earnings_minor = $16::integer,
               updated_at = now()
           WHERE id = $1
           RETURNING id
           """,
           [
             dump!(booking_id),
             pricing["finalAmountMinor"],
             pricing["finalAmountMinor"],
             pricing["coreAmountMinor"],
             pricing["sameDaySurchargeMinor"],
             pricing["weekendSurchargeMinor"],
             pricing["recurringDiscountMinor"],
             pricing["isSameDay"],
             pricing["isWeekend"],
             pricing["pricingVersion"],
             pricing["platformFeeMajor"],
             pricing["bookingCoverMajor"],
             pricing["workRateGhsPerHour"],
             pricing["suppliesOption"] || "customer_provided",
             pricing["suppliesAllowanceMinor"] || 0,
             pricing["cleanerEarningsMinor"]
           ]
         ) do
      {:ok, %{rows: [[_id]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp scheduled_at(%Date{} = date, time, timezone) do
    time = time || ~T[00:00:00]

    case Repo.query(
           "SELECT ($1::date + $2::time) AT TIME ZONE $3::text",
           [date, time, timezone]
         ) do
      {:ok, %{rows: [[%DateTime{} = at]]}} -> at
      {:ok, %{rows: [[%NaiveDateTime{} = at]]}} -> DateTime.from_naive!(at, "Etc/UTC")
      _ -> nil
    end
  end

  defp scheduled_at(_, _, _), do: nil

  defp dump!(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "invalid uuid"
    end
  end

  defp validate_reschedule_input(params) do
    with {:ok, scheduled_date} <- iso_date(params["scheduledDate"]),
         {:ok, scheduled_time} <- iso_time(params["scheduledTime"]) do
      duration =
        case params do
          %{"durationHours" => value} ->
            case positive_number(value) do
              {:ok, hours} -> hours
              :error -> :invalid
            end

          _ ->
            nil
        end

      if duration == :invalid do
        {:error, :invalid_request}
      else
        {:ok,
         %{
           scheduled_date: scheduled_date,
           scheduled_time: scheduled_time,
           duration_hours: duration,
           timezone:
             case params["timezone"] do
               value when is_binary(value) and value != "" -> normalize_timezone(value)
               _ -> nil
             end
         }}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_pricing_input(params) do
    with {:ok, service_id} <- positive_integer(params["serviceId"]),
         {:ok, cleaner_id} <- required_uuid(params["cleanerId"]),
         {:ok, scheduled_date} <- iso_date(params["scheduledDate"]),
         {:ok, duration_hours} <- positive_number(params["durationHours"]),
         {:ok, recurrence_interval} <- optional_recurrence_interval(params["recurrenceInterval"]) do
      {:ok,
       %{
         service_id: service_id,
         cleaner_id: cleaner_id,
         scheduled_date: scheduled_date,
         duration_hours: duration_hours,
         timezone: normalize_timezone(params["timezone"]),
         recurrence_interval: recurrence_interval
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_create_input(params) do
    with {:ok, input} <- validate_pricing_input(params),
         {:ok, scheduled_time} <- iso_time(params["scheduledTime"]),
         {:ok, address} <- required_text(params["address"], 3, 500),
         {:ok, idempotency_key} <- optional_idempotency_key(params["idempotencyKey"]),
         {:ok, visit} <- visit_details(params) do
      {:ok,
       Map.merge(input, %{
         scheduled_time: scheduled_time,
         address: address,
         special_instructions: optional_text(params["specialInstructions"], 4_000),
         idempotency_key: idempotency_key
       })
       |> Map.merge(visit)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp visit_details(params) do
    with {:ok, booking_for_self} <- boolean_param(params["bookingForSelf"], true),
         {:ok, requires_key} <- boolean_param(params["requiresKeyOrAccessCode"], false),
         {:ok, occupant_present} <- optional_boolean(params["occupantPresent"]),
         {:ok, property_type} <- optional_property_type(params["propertyType"]),
         {:ok, customer_contact_phone} <- optional_phone(params["customerContactPhone"]),
         {:ok, site_contact} <- site_contact(params, booking_for_self) do
      access_instructions =
        if requires_key, do: optional_text(params["accessInstructions"], 2_000), else: nil

      {:ok,
       %{
         booking_for_self: booking_for_self,
         requires_key_or_access_code: requires_key,
         occupant_present: occupant_present,
         property_type: property_type,
         customer_contact_phone: customer_contact_phone,
         access_instructions: access_instructions,
         site_contact_name: site_contact.name,
         site_contact_phone: site_contact.phone,
         site_contact_relationship: site_contact.relationship
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp site_contact(_params, true) do
    {:ok, %{name: nil, phone: nil, relationship: nil}}
  end

  defp site_contact(params, false) do
    with {:ok, name} <- required_text(params["siteContactName"], 2, 120),
         {:ok, phone} <- required_text(params["siteContactPhone"], 8, 24) do
      {:ok,
       %{
         name: name,
         phone: phone,
         relationship: optional_text(params["siteContactRelationship"], 80)
       }}
    else
      _ -> :error
    end
  end

  defp boolean_param(nil, default), do: {:ok, default}
  defp boolean_param(value, _default) when is_boolean(value), do: {:ok, value}
  defp boolean_param("true", _default), do: {:ok, true}
  defp boolean_param("false", _default), do: {:ok, false}
  defp boolean_param(_, _), do: :error

  defp optional_boolean(nil), do: {:ok, nil}
  defp optional_boolean(value) when is_boolean(value), do: {:ok, value}
  defp optional_boolean("true"), do: {:ok, true}
  defp optional_boolean("false"), do: {:ok, false}
  defp optional_boolean(_), do: :error

  defp optional_property_type(nil), do: {:ok, nil}
  defp optional_property_type(""), do: {:ok, nil}

  defp optional_property_type(value) when is_binary(value) do
    type = value |> String.trim() |> String.downcase()

    cond do
      type == "" -> {:ok, nil}
      type in @property_types -> {:ok, type}
      true -> :error
    end
  end

  defp optional_property_type(_), do: :error

  defp optional_phone(nil), do: {:ok, nil}
  defp optional_phone(""), do: {:ok, nil}

  defp optional_phone(value) when is_binary(value) do
    phone = String.trim(value)

    cond do
      phone == "" -> {:ok, nil}
      String.length(phone) >= 8 and String.length(phone) <= 24 -> {:ok, phone}
      true -> :error
    end
  end

  defp optional_phone(_), do: :error

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp optional_recurrence_interval(nil), do: {:ok, nil}

  defp optional_recurrence_interval(value) when is_binary(value) do
    interval = value |> String.trim() |> String.downcase()

    cond do
      interval == "" -> {:ok, nil}
      interval in @bookable_recurrence_intervals -> {:ok, interval}
      true -> :error
    end
  end

  defp optional_recurrence_interval(_), do: :error

  defp positive_minor(value) when is_integer(value) and value > 0, do: value

  defp positive_minor(value) when is_float(value) do
    integer = round(value)
    if integer > 0, do: integer, else: nil
  end

  defp positive_minor(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_minor(%Decimal{} = value) do
    integer = Decimal.to_integer(value)
    if integer > 0, do: integer, else: nil
  end

  defp positive_minor(_), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_), do: 0

  defp optional_idempotency_key(nil), do: {:ok, nil}

  defp optional_idempotency_key(value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) >= 8 and String.length(value) <= 128 do
      {:ok, value}
    else
      :error
    end
  end

  defp optional_idempotency_key(_), do: :error

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp positive_integer(_), do: :error

  defp positive_number(value) when is_number(value) and value > 0, do: {:ok, value}
  defp positive_number(_), do: :error

  defp iso_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp iso_date(_), do: :error

  defp iso_time(value) when is_binary(value) do
    value
    |> normalize_time_string()
    |> Time.from_iso8601()
  end

  defp iso_time(_), do: :error

  defp normalize_time_string(<<h1, h2, ?:, m1, m2>>), do: <<h1, h2, ?:, m1, m2, ?:, ?0, ?0>>
  defp normalize_time_string(value), do: value

  defp required_text(value, min, max) when is_binary(value) do
    value = String.trim(value)
    if String.length(value) >= min and String.length(value) <= max, do: {:ok, value}, else: :error
  end

  defp required_text(_, _, _), do: :error

  defp optional_text(nil, _max), do: nil

  defp optional_text(value, max) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, max)

  defp optional_text(_, _max), do: nil

  defp normalize_timezone(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @default_timezone
      timezone -> timezone
    end
  end

  defp normalize_timezone(_), do: @default_timezone

  defp required_uuid(value) do
    case dump_uuid(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp amount_minor(%Decimal{} = value), do: Decimal.to_integer(value)
  defp amount_minor(value) when is_integer(value), do: value
  defp amount_minor(value) when is_float(value), do: round(value)

  defp amount_minor(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp amount_minor(_), do: nil

  defp decimal_hours(%Decimal{} = value), do: value
  defp decimal_hours(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_hours(value) when is_float(value), do: Decimal.from_float(value)

  defp format_hhmm(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  defp clear_reminder(column) do
    """
    CASE
      WHEN scheduled_date IS DISTINCT FROM $2
        OR scheduled_time IS DISTINCT FROM $3
        OR COALESCE(
          NULLIF(btrim(timezone_name), ''),
          NULLIF(btrim(timezone), ''),
          '#{@default_timezone}'
        ) IS DISTINCT FROM $5::text
      THEN NULL
      ELSE #{column}
    END
    """
  end

  def client_bookings_enabled? do
    Application.get_env(:mithril, :direct_client_bookings, false) == true
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp dump_optional_uuid(value) when is_binary(value) and value != "" do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> nil
    end
  end

  defp dump_optional_uuid(_), do: nil

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp database_error(error) do
    Logger.error("Direct bookings database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
