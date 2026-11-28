defmodule Mithril.DirectBookings do
  @moduledoc """
  Customer booking reads and writes for Instaclean Direct.

  Pricing is delegated to the same PostgreSQL `compute_booking_pricing` function
  used by the legacy web/mobile clients. Direct never accepts a client-computed
  amount or customer id.
  """

  require Logger

  alias Mithril.FamilyCareSchedule
  alias Mithril.Paystack
  alias Mithril.Repo
  alias Mithril.Stripe

  @default_timezone "Africa/Accra"
  # Paystack plan intervals. Hourly and legacy bi-weekly stay unbookable.
  @bookable_recurrence_intervals ~w(daily weekly monthly quarterly annually)
  @family_care_multiday_checkout_message "Weekly, monthly, and multi-day family care cannot be booked yet. Choose one visit."
  @property_types ~w(residential vacant_home office commercial airbnb_turnover post_construction)
  # Preserve operationally distinct linen choices; existing legacy values remain accepted.
  @linen_handling ~w(replace_no_wash wash_hang_dry wash_dry_repack_onsite no_bedding_replace clean_linen_provided launder_on_site no_linen_change)
  @turnover_sources ~w(manual airbnb_ical)
  # Paystack statuses that prove the reference was not captured.
  @terminal_paystack_statuses ~w(abandoned failed reversed refunded)

  def list_services do
    # `service_types.duration` is a display string like "2 hours", so it cannot
    # be coalesced with numeric hour columns.
    case Repo.query("""
         SELECT jsonb_build_object(
           'id', id,
           'name', name,
           'category', category::text,
           'categoryId', category_id,
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
         {:ok, legacy} <- legacy_booking_metadata(params),
         {:ok, service} <- service_details(input.service_id),
         :ok <- cleaner_eligible(input.cleaner_id, service.specialty_slug),
         {:ok, pricing} <- compute_pricing(Map.merge(input, legacy)) do
      {:ok,
       pricing
       |> Map.delete("cleanerEarningsMinor")
       |> Map.delete("includeBookingCover")}
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
                 :ok <- validate_turnover_context(customer_id, input, pricing),
                 :ok <- assert_family_care_visits(input, pricing),
                 :ok <- assert_pet_care_visits(input, pricing),
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

        with {:ok, gate} <- open_checkout_gate(customer_id, bid, replacement_input) do
          case gate do
            {:resume, result} ->
              {:ok, result}

            :replace ->
              Repo.transaction(fn ->
                with {:ok, original} <- lock_unpaid_replacement_booking(customer_id, bid),
                     :ok <-
                       lock_booking_idempotency(customer_id, replacement_input.idempotency_key),
                     {:ok, existing} <-
                       find_idempotent_booking(customer_id, replacement_input.idempotency_key),
                     {:ok, path} <- replacement_path(original, existing),
                     {:ok, result} <-
                       execute_unpaid_replacement(
                         path,
                         customer_id,
                         bid,
                         replacement_input
                         |> merge_replacement_visit_details(original, params)
                         |> merge_replacement_legacy_details(original, params),
                         existing
                       ) do
                  result
                else
                  {:error, reason} -> Repo.rollback(reason)
                end
              end)
              |> normalize_transaction()
          end
        end
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
                  requires_key_or_access_code, access_instructions, customer_contact_phone,
                  turnover_guest_checkout_at, turnover_next_checkin_at,
                  turnover_linen_handling, turnover_restocking_notes, turnover_source,
                  turnover_opportunity_id, property_id,
                  home_size, extra_task_ids, duration_adjustment,
                  service_duration_option_id::text, booking_source
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
             customer_contact_phone,
             turnover_guest_checkout_at,
             turnover_next_checkin_at,
             turnover_linen_handling,
             turnover_restocking_notes,
             turnover_source,
             turnover_opportunity_id,
             property_id,
             home_size,
             extra_task_ids,
             duration_adjustment,
             service_duration_option_id,
             booking_source
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
             customer_contact_phone: customer_contact_phone,
             turnover_guest_checkout_at: turnover_guest_checkout_at,
             turnover_next_checkin_at: turnover_next_checkin_at,
             turnover_linen_handling: turnover_linen_handling,
             turnover_restocking_notes: turnover_restocking_notes,
             turnover_source: turnover_source,
             turnover_opportunity_id: turnover_opportunity_id,
             property_id: property_id
           },
           legacy: %{
             home_size: home_size,
             extra_task_ids: normalize_extra_task_ids(extra_task_ids),
             duration_adjustment: decimal_number(duration_adjustment) || 0,
             service_duration_option_id: service_duration_option_id,
             booking_source: booking_source
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
      "customerContactPhone" => :customer_contact_phone,
      "turnoverGuestCheckoutAt" => :turnover_guest_checkout_at,
      "turnoverNextCheckInAt" => :turnover_next_checkin_at,
      "turnoverLinenHandling" => :turnover_linen_handling,
      "turnoverRestockingNotes" => :turnover_restocking_notes,
      "turnoverSource" => :turnover_source,
      "turnoverOpportunityId" => :turnover_opportunity_id,
      "propertyId" => :property_id
    }

    Enum.reduce(mapping, input, fn {key, field}, acc ->
      if Map.has_key?(params, key) do
        acc
      else
        Map.put(acc, field, original.visit[field])
      end
    end)
  end

  defp merge_replacement_legacy_details(input, original, params) do
    mapping = %{
      "homeSize" => :home_size,
      "extraTaskIds" => :extra_task_ids,
      "durationAdjustment" => :duration_adjustment,
      "serviceDurationOptionId" => :service_duration_option_id,
      "bookingSource" => :booking_source,
      "visitDurationHours" => :visit_duration_hours
    }

    Enum.reduce(mapping, input, fn {key, field}, acc ->
      if Map.has_key?(params, key) do
        acc
      else
        Map.put(acc, field, original.legacy[field])
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
    with {:ok, attempts} <- open_payment_attempts(booking_id),
         :ok <- reconcile_open_attempts(customer_id, booking_id, attempts),
         :ok <- retire_reconciled_attempts(booking_id, Enum.map(attempts, & &1.id)),
         :ok <- cancel_original_for_replacement(customer_id, booking_id) do
      if reusable_replacement?(existing) do
        {:ok, existing}
      else
        create_booking_locked(customer_id, input)
      end
    end
  end

  # Same service, worker, schedule, address, and price: keep the checkout the
  # customer already started. Payment reopens that Paystack URL or Stripe secret.
  # A real change retires a Paystack attempt only after the booking row is locked
  # and Paystack says the reference was not charged, or the captured charge is
  # refunded. The lock stops a webhook from marking that charge paid underneath.
  defp open_checkout_gate(customer_id, booking_id, input) do
    with {:ok, existing} <- find_idempotent_booking(customer_id, input.idempotency_key) do
      if reusable_replacement?(existing) do
        {:ok, :replace}
      else
        classify_open_checkout(customer_id, booking_id, input)
      end
    end
  end

  defp classify_open_checkout(customer_id, booking_id, input) do
    with {:ok, attempts} <- open_payment_attempts(booking_id) do
      if attempts == [] do
        {:ok, :replace}
      else
        classify_open_attempts(customer_id, booking_id, input, attempts)
      end
    end
  end

  defp classify_open_attempts(customer_id, booking_id, input, attempts) do
    case fetch_replacement_identity(customer_id, booking_id) do
      {:ok, booking} ->
        if payable_replacement?(booking) do
          classify_payable_checkout(booking, input, attempts)
        else
          {:ok, :replace}
        end

      {:error, :not_found} ->
        {:ok, :replace}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_payable_checkout(booking, input, attempts) do
    case same_open_checkout?(booking, input, attempts) do
      {:ok, true} ->
        {:ok, {:resume, resume_booking_result(booking)}}

      {:ok, false} ->
        {:ok, :replace}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp payable_replacement?(booking) do
    booking.status == "pending" and booking.payment_status in ["pending", "unpaid"]
  end

  defp resume_booking_result(booking) do
    booking_result(
      booking.id,
      booking.status,
      booking.payment_status,
      booking.amount_minor,
      booking.currency,
      booking.subscription_id
    )
  end

  defp fetch_replacement_identity(customer_id, booking_id) do
    case Repo.query(
           """
           SELECT id::text, status::text, payment_status::text, subscription_id::text,
                  service_id, cleaner_id::text, scheduled_date, scheduled_time,
                  duration_hours, address,
                  COALESCE(final_amount_minor, total_price),
                  COALESCE(currency, 'GHS')
           FROM public.bookings
           WHERE id = $1 AND customer_id = $2
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
             service_id,
             cleaner_id,
             scheduled_date,
             scheduled_time,
             duration_hours,
             address,
             amount_minor,
             currency
           ]
         ]
       }} ->
        {:ok,
         %{
           id: id,
           status: status,
           payment_status: payment_status,
           subscription_id: subscription_id,
           service_id: service_id,
           cleaner_id: cleaner_id,
           scheduled_date: scheduled_date,
           scheduled_time: scheduled_time,
           duration_hours: duration_hours,
           address: address,
           amount_minor: amount_minor,
           currency: currency
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp open_payment_attempts(booking_id) do
    case Repo.query(
           """
           SELECT id::text, reference, status, amount_minor, currency,
                  COALESCE(provider, 'paystack'), stripe_payment_intent_id
           FROM public.payment_attempts
           WHERE booking_id = $1
             AND status IN ('initializing', 'ready')
           """,
           [booking_id]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [id, reference, status, amount, currency, provider, intent_id] ->
           %{
             id: id,
             reference: reference,
             status: status,
             amount_minor: amount,
             currency: currency,
             provider: provider,
             stripe_payment_intent_id: intent_id
           }
         end)}

      {:error, error} ->
        database_error(error)
    end
  end

  defp same_open_checkout?(booking, input, attempts) do
    case compute_pricing(input) do
      {:ok, pricing} ->
        price = amount_minor(pricing["finalAmountMinor"])
        currency = pricing["currency"]

        {:ok,
         booking.service_id == input.service_id and
           same_id?(booking.cleaner_id, input.cleaner_id) and
           same_date?(booking.scheduled_date, input.scheduled_date) and
           same_time?(booking.scheduled_time, input.scheduled_time) and
           same_number?(booking.duration_hours, input.duration_hours) and
           same_text?(booking.address, input.address) and
           amount_minor(booking.amount_minor) == price and
           same_currency?(booking.currency, currency) and
           attempts_match_price?(attempts, price, currency)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempts_match_price?(attempts, price, currency) when is_integer(price) do
    Enum.all?(attempts, fn attempt ->
      amount_minor(attempt.amount_minor) == price and
        same_currency?(attempt.currency, currency)
    end)
  end

  defp attempts_match_price?(_attempts, _price, _currency), do: false

  defp reconcile_open_attempts(customer_id, booking_id, attempts) do
    Enum.reduce_while(attempts, :ok, fn attempt, :ok ->
      case reconcile_open_attempt(customer_id, booking_id, attempt) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_open_attempt(_customer_id, _booking_id, %{
         provider: "stripe",
         stripe_payment_intent_id: intent_id
       })
       when is_binary(intent_id) and intent_id != "" do
    case Stripe.cancel_payment_intent(intent_id) do
      :ok -> :ok
      {:error, _} -> {:error, :payment_in_progress}
    end
  end

  defp reconcile_open_attempt(_customer_id, _booking_id, %{provider: "stripe"}), do: :ok

  defp reconcile_open_attempt(customer_id, booking_id, %{provider: "paystack"} = attempt) do
    reconcile_paystack_attempt(customer_id, booking_id, attempt)
  end

  defp reconcile_open_attempt(_customer_id, _booking_id, _attempt),
    do: {:error, :payment_in_progress}

  defp reconcile_paystack_attempt(customer_id, booking_id, attempt) do
    reference = attempt.reference

    if is_binary(reference) and reference != "" do
      case Paystack.verify(reference) do
        {:ok, receipt} ->
          reconcile_paystack_receipt(customer_id, booking_id, attempt, receipt)

        {:error, :not_found} ->
          :ok

        {:error, {:provider, 404, _message}} ->
          :ok

        {:error, _} ->
          {:error, :payment_in_progress}
      end
    else
      {:error, :payment_in_progress}
    end
  end

  defp reconcile_paystack_receipt(customer_id, booking_id, attempt, receipt) do
    case provider_status(receipt) do
      "success" ->
        refund_paystack_charge(customer_id, booking_id, attempt)

      status when status in @terminal_paystack_statuses ->
        :ok

      _status ->
        {:error, :payment_in_progress}
    end
  end

  defp refund_paystack_charge(customer_id, booking_id, attempt) do
    case Paystack.refund(%{
           transaction: attempt.reference,
           amount: amount_minor(attempt.amount_minor),
           currency: attempt.currency,
           customer_note: "Replaced by a new Instaclean checkout"
         }) do
      {:ok, refund} ->
        record_replaced_refund(customer_id, booking_id, attempt, refund_reference(refund))

      {:error, _reason} ->
        case Paystack.verify(attempt.reference) do
          {:ok, receipt} ->
            if provider_status(receipt) in ["reversed", "refunded"] do
              record_replaced_refund(customer_id, booking_id, attempt, nil)
            else
              if provider_status(receipt) in @terminal_paystack_statuses do
                :ok
              else
                {:error, :payment_in_progress}
              end
            end

          {:error, _} ->
            {:error, :payment_in_progress}
        end
    end
  end

  defp record_replaced_refund(customer_id, booking_id, attempt, paystack_refund_reference) do
    case Repo.query(
           """
           INSERT INTO public.booking_refunds (
             booking_id, customer_id, tier, refund_percent, refund_amount_minor,
             paystack_transaction_reference, paystack_refund_reference, status
           ) VALUES ($1, $2, 'full', 100, $3, $4, $5, 'pending')
           """,
           [
             booking_id,
             customer_id,
             amount_minor(attempt.amount_minor),
             attempt.reference,
             paystack_refund_reference
           ]
         ) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        :ok

      {:error, error} ->
        database_error(error)
    end
  end

  defp refund_reference(%{id: id}) when is_binary(id) and id != "", do: id
  defp refund_reference(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp refund_reference(_refund), do: nil

  defp provider_status(receipt) when is_map(receipt) do
    case receipt[:status] || receipt["status"] do
      status when is_binary(status) -> String.downcase(status)
      _status -> nil
    end
  end

  defp provider_status(_receipt), do: nil

  defp retire_reconciled_attempts(booking_id, attempt_ids) do
    with :ok <- fail_reconciled_attempts(booking_id, attempt_ids) do
      confirm_no_open_attempts(booking_id)
    end
  end

  defp fail_reconciled_attempts(_booking_id, []), do: :ok

  defp fail_reconciled_attempts(booking_id, attempt_ids) do
    case Repo.query(
           """
           UPDATE public.payment_attempts
           SET status = 'failed',
               failure_reason = 'Replaced by a new checkout',
               failed_at = COALESCE(failed_at, now()),
               updated_at = now()
           WHERE booking_id = $1
             AND id::text = ANY($2::text[])
             AND status IN ('initializing', 'ready')
           """,
           [booking_id, attempt_ids]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp confirm_no_open_attempts(booking_id) do
    case Repo.query(
           """
           SELECT EXISTS (
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

  defp same_id?(left, right) do
    case {uuid_string(left), uuid_string(right)} do
      {{:ok, left_id}, {:ok, right_id}} -> String.downcase(left_id) == String.downcase(right_id)
      _other -> false
    end
  end

  defp uuid_string(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp uuid_string(_value), do: :error

  defp same_date?(%Date{} = left, %Date{} = right), do: Date.compare(left, right) == :eq
  defp same_date?(_left, _right), do: false

  defp same_time?(%Time{} = left, %Time{} = right) do
    Time.compare(Time.truncate(left, :second), Time.truncate(right, :second)) == :eq
  end

  defp same_time?(_left, _right), do: false

  defp same_number?(left, right) do
    case {decimal_number(left), decimal_number(right)} do
      {left_number, right_number}
      when is_number(left_number) and is_number(right_number) ->
        left_number == right_number

      _other ->
        false
    end
  end

  defp same_text?(left, right) do
    text = normalized_checkout_text(left)
    text != "" and text == normalized_checkout_text(right)
  end

  defp normalized_checkout_text(value) when is_binary(value), do: String.trim(value)
  defp normalized_checkout_text(_value), do: ""

  defp same_currency?(left, right) when is_binary(left) and is_binary(right) do
    String.upcase(left) == String.upcase(right)
  end

  defp same_currency?(_left, _right), do: false

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
      {:ok, %{rows: [[_id]]}} ->
        release_turnover_claim(booking_id)

      {:ok, %{rows: []}} ->
        {:error, :cancel_conflict}

      {:error, error} ->
        database_error(error)
    end
  end

  defp release_turnover_claim(booking_id) do
    case Repo.query(
           """
           UPDATE public.turnover_opportunities
           SET booking_id = NULL, status = 'ready_to_book', updated_at = now()
           WHERE booking_id = $1::uuid
           """,
           [booking_id]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp create_booking_locked(customer_id, input) do
    with {:ok, service} <- service_details(input.service_id),
         :ok <- cleaner_eligible(input.cleaner_id, service.specialty_slug),
         {:ok, pricing} <- compute_pricing(input),
         :ok <- validate_turnover_context(customer_id, input, pricing),
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
             :ok <- validate_reschedule_turnover(booking, schedule, pricing),
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
    with {:ok, service} <- service_details(input.service_id) do
      family_care = Map.get(input, :family_care)
      pet_care = Map.get(input, :pet_care)

      cond do
        service.family_care? and is_map(family_care) and is_nil(pet_care) ->
          compute_family_care_checkout_pricing(input, family_care)

        service.pet_care? and is_map(pet_care) and is_nil(family_care) ->
          compute_pet_care_checkout_pricing(input, pet_care)

        not service.family_care? and not service.pet_care? and is_nil(family_care) and
            is_nil(pet_care) ->
          compute_standard_pricing(input)

        true ->
          {:error, :invalid_request}
      end
    end
  end

  defp compute_standard_pricing(input) do
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
             p_include_booking_cover => $11::boolean,
             p_supplies_option => 'customer_provided'::text,
             p_cleaner_id => $5::uuid,
             p_extra_task_ids => $8::text[],
             p_service_duration_option_id => $9::uuid,
             p_visit_duration_hours => $10::numeric,
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
             is_binary(Map.get(input, :recurrence_interval)),
             legacy_extra_task_ids_for_pricing(input),
             legacy_service_duration_option_id(input),
             legacy_visit_duration_hours_for_pricing(input),
             include_booking_cover?(input)
           ]
         ) do
      {:ok, %{rows: [[pricing]]}} ->
        {:ok, Map.put(pricing, "includeBookingCover", include_booking_cover?(input))}

      {:ok, %{rows: []}} ->
        {:error, :pricing_unavailable}

      {:error, error} ->
        Logger.warning("Direct booking pricing failed: #{inspect(error)}")
        {:error, :pricing_unavailable}
    end
  end

  defp compute_family_care_checkout_pricing(input, care) do
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
             'suppliesOption', 'customer_provided',
             'suppliesAllowanceMinor', 0,
             'cleanerEarningsMinor', p.cleaner_earnings_minor,
             'recurringAmountMinor', p.recurring_amount_minor,
             'firstChargeAmountMinor', p.first_charge_amount_minor,
             'discountRateBps', p.discount_rate_bps
           ), p.billable_days
           FROM public.compute_family_care_pricing(
             $1::integer,
             $2::text,
             $3::integer,
             $4::date,
             $5::text,
             $6::numeric,
             $7::integer,
             $8::boolean,
             $9::boolean,
             $10::boolean,
             $11::text[]
           ) p
           """,
           [
             input.service_id,
             care.care_package,
             care.child_count,
             input.scheduled_date,
             care.frequency,
             care.custom_daily_major,
             care.selected_day_count,
             care.mobility,
             care.errands,
             care.appointments,
             care.weekdays
           ]
         ) do
      {:ok, %{rows: [[pricing, days]]}} when is_integer(days) and days >= 1 ->
        {:ok,
         pricing
         |> Map.put("includeBookingCover", false)
         |> Map.put("billableDays", days)}

      {:ok, %{rows: []}} ->
        {:error, :pricing_unavailable}

      {:error, %Postgrex.Error{postgres: %{code: :raise_exception, message: message}}}
      when is_binary(message) and message != "" ->
        {:error, {:invalid_request, message}}

      {:error, error} ->
        Logger.warning("Family care booking pricing failed: #{inspect(error)}")
        {:error, :pricing_unavailable}
    end
  end

  defp compute_pet_care_checkout_pricing(input, care) do
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
             'suppliesOption', 'customer_provided',
             'suppliesAllowanceMinor', 0,
             'cleanerEarningsMinor', p.cleaner_earnings_minor,
             'recurringAmountMinor', p.recurring_amount_minor,
             'firstChargeAmountMinor', p.first_charge_amount_minor,
             'discountRateBps', p.discount_rate_bps
           ), p.billable_days
           FROM public.compute_pet_care_pricing(
             $1::integer,
             $2::text,
             $3::integer,
             $4::date,
             $5::text,
             $6::numeric,
             $7::integer,
             $8::boolean,
             $9::boolean
           ) p
           """,
           [
             input.service_id,
             care.care_package,
             care.pet_count,
             input.scheduled_date,
             care.frequency,
             care.custom_visit_major,
             care.selected_day_count,
             care.extra_attention,
             care.medication_required
           ]
         ) do
      {:ok, %{rows: [[pricing, days]]}} when is_integer(days) and days >= 1 ->
        {:ok,
         pricing
         |> Map.put("includeBookingCover", false)
         |> Map.put("billableDays", days)}

      {:ok, %{rows: []}} ->
        {:error, :pricing_unavailable}

      {:error, %Postgrex.Error{postgres: %{code: :raise_exception, message: message}}}
      when is_binary(message) and message != "" ->
        {:error, {:invalid_request, message}}

      {:error, error} ->
        Logger.warning("Pet care booking pricing failed: #{inspect(error)}")
        {:error, :pricing_unavailable}
    end
  end

  defp include_booking_cover?(input) do
    Map.get(input, :include_booking_cover, true) != false
  end

  defp service_details(service_id) do
    case Repo.query(
           """
           SELECT st.name, st.specialty_slug,
                  COALESCE(sc.slug = 'caregiving', false)
                    OR COALESCE(st.specialty_slug IN ('child_care', 'senior_care'), false),
                  COALESCE(
                    st.specialty_slug IN ('pet_sitting', 'dog_walking', 'feeding_checkins'),
                    false
                  )
           FROM public.service_types st
           LEFT JOIN public.service_categories sc ON sc.id = st.category_id
           WHERE st.id = $1 AND st.active = true
           LIMIT 1
           """,
           [service_id]
         ) do
      {:ok, %{rows: [[name, specialty_slug, family_care?, pet_care?]]}}
      when is_binary(specialty_slug) and specialty_slug != "" ->
        {:ok,
         %{
           name: name,
           specialty_slug: specialty_slug,
           family_care?: family_care?,
           pet_care?: pet_care?
         }}

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
    if family_care_day_rate?(input, pricing) do
      validate_family_care_start(input)
    else
      validate_workday_timeslot(input, pricing)
    end
  end

  # Care visits are priced as a package. A full day or overnight often starts at noon
  # and lasts past 5pm, so the cleaning workday rule would reject a normal visit.
  # The visit still has to start in the future.
  defp family_care_day_rate?(%{family_care: care}, _pricing) when is_map(care), do: true
  defp family_care_day_rate?(%{pet_care: care}, _pricing) when is_map(care), do: true
  defp family_care_day_rate?(_input, %{"pricingVersion" => "family_care_v1"}), do: true
  defp family_care_day_rate?(_input, %{"pricingVersion" => "pet_care_v1"}), do: true
  defp family_care_day_rate?(_input, _pricing), do: false

  defp validate_family_care_start(input) do
    case scheduled_at(input.scheduled_date, input.scheduled_time, input.timezone) do
      %DateTime{} = starts_at ->
        if DateTime.compare(starts_at, DateTime.utc_now()) == :gt do
          :ok
        else
          {:error, :invalid_timeslot}
        end

      _ ->
        {:error, :invalid_timeslot}
    end
  end

  defp validate_workday_timeslot(input, pricing) do
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
             (
               EXISTS(
                 SELECT 1
                 FROM public.cleaner_availability_exceptions cae
                 WHERE cae.cleaner_id = $1::uuid
                   AND cae.exception_date = $2::date
               )
               OR EXISTS(
                 SELECT 1
                 FROM public.cleaner_weekday_blocks block
                 WHERE block.cleaner_id = $1::uuid
                   AND block.day_of_week = EXTRACT(DOW FROM $2::date)::int
               )
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
    if Map.get(input, :property_type) == "airbnb_turnover" or
         not is_nil(Map.get(input, :turnover_opportunity_id)) or
         not is_nil(Map.get(input, :property_id)) do
      {:error, :invalid_request}
    else
      maybe_insert_standard_subscription(customer_id, input, pricing)
    end
  end

  defp maybe_insert_standard_subscription(customer_id, input, pricing) do
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
             billing_mode,
             home_size,
             extra_task_ids,
             family_care_schedule
           ) VALUES (
             $1, $2, $3, $4, $5::numeric, $6, $7, $7, $8, $9, $10,
             $6, $11, 'pending', $12::date, $12::date, $13::time, NULLIF($14::text, ''),
             $6, 'paystack_plan', NULLIF($15::text, ''), $16::text[], $17::text::jsonb
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
             input.special_instructions || "",
             blank_to_nil(Map.get(input, :home_size)),
             legacy_extra_task_ids_for_storage(input),
             family_care_schedule_json(input, pricing)
           ]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:error, error} -> database_error(error)
    end
  end

  defp insert_booking(customer_id, input, pricing, service_name) do
    with {:ok, subscription_id} <- maybe_insert_subscription(customer_id, input, pricing),
         {:ok, booking_id} <-
           insert_booking_row(customer_id, input, pricing, service_name, subscription_id),
         :ok <- claim_turnover_opportunity(customer_id, input, booking_id) do
      {:ok, booking_id, subscription_id}
    end
  end

  defp claim_turnover_opportunity(_customer_id, %{turnover_opportunity_id: nil}, _booking_id),
    do: :ok

  defp claim_turnover_opportunity(customer_id, input, booking_id) do
    case Repo.query(
           """
           UPDATE public.turnover_opportunities o
           SET booking_id = $2::uuid, status = 'booked', updated_at = now()
           FROM public.properties p
           WHERE o.id = $1::uuid
             AND p.id = o.property_id
             AND p.customer_id = $3::uuid
             AND (o.booking_id IS NULL OR o.booking_id = $2::uuid)
             AND o.status IN ('needs_review', 'ready_to_book', 'conflict', 'booked')
           RETURNING o.id
           """,
           [input.turnover_opportunity_id, booking_id, customer_id]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :invalid_request}
      {:error, error} -> database_error(error)
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
             customer_contact_phone,
             turnover_guest_checkout_at,
             turnover_next_checkin_at,
             turnover_linen_handling,
             turnover_restocking_notes,
             turnover_source,
             turnover_opportunity_id,
             property_id,
             direct_assigned_cleaner_id,
             home_size,
             extra_task_ids,
             duration_adjustment,
             service_duration_option_id,
             booking_source
           ) VALUES (
             $1, $2, $3, $4, $5::date, $6::time, $7, $7, $8,
             NULLIF($9::text, ''), $10::numeric, $11::integer, $12::integer,
             $13::integer, $14::integer, $15::integer,
             $16, $17, $18, $19, $20, 0, $52, $21, $22, $23,
             $24::integer, $25::integer, 'pending', 'pending', $26, $27,
             $28::uuid, NULLIF($29::text, ''),
             $30, NULLIF($31::text, ''), NULLIF($32::text, ''), NULLIF($33::text, ''),
             NULLIF($34::text, ''), $35, $36, NULLIF($37::text, ''), NULLIF($38::text, ''),
             $39::timestamptz, $40::timestamptz, NULLIF($41::text, ''), NULLIF($42::text, ''),
             NULLIF($43::text, ''), $44::uuid, $45::uuid, $46::uuid,
             NULLIF($47::text, ''), $48::text[], $49::numeric, $50::uuid, NULLIF($51::text, '')
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
             blank_to_nil(Map.get(input, :customer_contact_phone)),
             Map.get(input, :turnover_guest_checkout_at),
             Map.get(input, :turnover_next_checkin_at),
             blank_to_nil(Map.get(input, :turnover_linen_handling)),
             blank_to_nil(Map.get(input, :turnover_restocking_notes)),
             blank_to_nil(Map.get(input, :turnover_source)),
             Map.get(input, :turnover_opportunity_id),
             Map.get(input, :property_id),
             if(Map.get(input, :direct_assignment) == true, do: input.cleaner_id, else: nil),
             blank_to_nil(Map.get(input, :home_size)),
             legacy_extra_task_ids_for_storage(input),
             decimal_hours(Map.get(input, :duration_adjustment, 0) || 0),
             dump_optional_uuid(Map.get(input, :service_duration_option_id)),
             blank_to_nil(Map.get(input, :booking_source)),
             Map.get(pricing, "includeBookingCover", true) != false
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
             ) AS timezone,
             turnover_guest_checkout_at, turnover_next_checkin_at, turnover_opportunity_id, property_id,
             COALESCE(b.booking_cover, true),
             b.pricing_version
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
         timezone,
         turnover_guest_checkout_at,
         turnover_next_checkin_at,
         turnover_opportunity_id,
         property_id,
         booking_cover,
         pricing_version
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
      timezone: timezone || @default_timezone,
      turnover_guest_checkout_at: turnover_guest_checkout_at,
      turnover_next_checkin_at: turnover_next_checkin_at,
      turnover_opportunity_id: turnover_opportunity_id,
      property_id: property_id,
      booking_cover: booking_cover != false,
      pricing_version: pricing_version
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
        :unpaid when booking.pricing_version in ["family_care_v1", "pet_care_v1"] ->
          booking.duration_hours
        :unpaid -> input.duration_hours || booking.duration_hours
      end

    %{
      cleaner_id: booking.cleaner_id,
      service_id: booking.service_id,
      scheduled_date: input.scheduled_date,
      scheduled_time: input.scheduled_time,
      duration_hours: duration_hours,
      timezone: input.timezone || booking.timezone,
      include_booking_cover: Map.get(booking, :booking_cover, true) != false
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
    {:ok, reschedule_timeslot_quote(booking)}
  end

  defp reschedule_pricing(:unpaid, %{pricing_version: version} = booking, _schedule)
       when version in ["family_care_v1", "pet_care_v1"] do
    {:ok, reschedule_timeslot_quote(booking)}
  end

  defp reschedule_pricing(:unpaid, _booking, schedule) do
    compute_pricing(schedule)
  end

  defp reschedule_timeslot_quote(booking) do
    %{
      "durationHours" => booking.duration_hours,
      "pricingVersion" => booking.pricing_version
    }
  end

  defp apply_reschedule(:paid, booking, schedule, _pricing, customer_id) do
    update_reschedule_schedule(booking, schedule, customer_id, :paid)
  end

  defp apply_reschedule(
         :unpaid,
         %{pricing_version: version} = booking,
         schedule,
         _pricing,
         customer_id
       )
       when version in ["family_care_v1", "pet_care_v1"] do
    update_reschedule_schedule(booking, schedule, customer_id, :unpaid)
  end

  defp apply_reschedule(:unpaid, booking, schedule, pricing, customer_id) do
    with :ok <- update_reschedule_schedule(booking, schedule, customer_id, :unpaid) do
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
                   failure_reason = 'Booking price changed',
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

  # Reprice an unpaid visit after staff change the extra tasks. The stored
  # promotion is applied again so the edit does not drop the discount.
  def reprice_unpaid_booking(booking_id) do
    with {:ok, bid} <- dump_uuid(booking_id),
         {:ok, booking} <- load_reprice_booking(bid),
         input <- reprice_input(booking),
         {:ok, pricing} <- compute_pricing(input),
         :ok <- validate_timeslot(input, pricing),
         :ok <- validate_cleaner_availability(input, pricing, bid) do
      update_unpaid_pricing(booking_id, pricing)
    end
  end

  def preserve_promotion_charge(final_minor, discount_minor) do
    final = amount_minor(final_minor) || 0
    discount = amount_minor(discount_minor) || 0
    max(final - max(discount, 0), 0)
  end

  defp load_reprice_booking(bid) do
    case Repo.query(
           """
           SELECT service_id,
                  cleaner_id,
                  scheduled_date,
                  scheduled_time,
                  duration_hours,
                  COALESCE(NULLIF(btrim(timezone), ''), 'Africa/Accra'),
                  extra_task_ids,
                  status::text,
                  payment_status::text,
                  subscription_id,
                  COALESCE(booking_cover, true)
           FROM public.bookings
           WHERE id = $1
           FOR UPDATE
           """,
           [bid]
         ) do
      {:ok,
       %{
         rows: [
           [
             service_id,
             cleaner_id,
             scheduled_date,
             scheduled_time,
             duration_hours,
             timezone,
             extra_task_ids,
             status,
             payment_status,
             subscription_id,
             booking_cover
           ]
         ]
       }} ->
        cond do
          not is_nil(subscription_id) ->
            {:error, :not_cancellable}

          status not in ["pending", "confirmed"] ->
            {:error, :not_cancellable}

          is_binary(payment_status) and payment_status not in ["pending", "failed"] ->
            {:error, :already_paid}

          true ->
            {:ok,
             %{
               service_id: service_id,
               cleaner_id: cleaner_id,
               scheduled_date: scheduled_date,
               scheduled_time: scheduled_time,
               duration_hours: decimal_number(duration_hours),
               timezone: timezone,
               extra_task_ids: normalize_extra_task_ids(extra_task_ids),
               include_booking_cover: booking_cover != false
             }}
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp reprice_input(booking) do
    %{
      service_id: booking.service_id,
      cleaner_id: booking.cleaner_id,
      scheduled_date: booking.scheduled_date,
      scheduled_time: booking.scheduled_time,
      duration_hours: booking.duration_hours,
      timezone: booking.timezone,
      extra_task_ids: booking.extra_task_ids,
      include_booking_cover: Map.get(booking, :include_booking_cover, true) != false
    }
  end

  defp stored_reprice_amounts(booking_id) do
    case Repo.query(
           """
           SELECT COALESCE(promotion_discount_minor, 0), final_amount_minor
           FROM public.bookings
           WHERE id = $1
           FOR UPDATE
           """,
           [dump!(booking_id)]
         ) do
      {:ok, %{rows: [[discount, amount]]}} -> {:ok, %{discount: discount, amount_minor: amount}}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp update_unpaid_pricing(booking_id, pricing) do
    with {:ok, stored} <- stored_reprice_amounts(booking_id) do
      charged = preserve_promotion_charge(pricing["finalAmountMinor"], stored.discount)
      next_pricing = Map.put(pricing, "finalAmountMinor", charged)

      with :ok <-
             maybe_invalidate_repriced_checkout(
               %{id: booking_id, amount_minor: stored.amount_minor},
               next_pricing
             ) do
        write_unpaid_pricing(booking_id, next_pricing)
      end
    end
  end

  defp write_unpaid_pricing(booking_id, pricing) do
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
               booking_cover = $17,
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
             pricing["cleanerEarningsMinor"],
             Map.get(pricing, "includeBookingCover", true) != false
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
         {:ok, recurrence_interval} <- optional_recurrence_interval(params["recurrenceInterval"]),
         {:ok, include_booking_cover} <- boolean_param(params["includeBookingCover"], true),
         {:ok, family_care} <- optional_family_care(params),
         {:ok, pet_care} <- optional_pet_care(params),
         :ok <- validate_family_care_visit(family_care, recurrence_interval),
         :ok <- validate_pet_care_visit(pet_care, recurrence_interval) do
      {:ok,
       %{
         service_id: service_id,
         cleaner_id: cleaner_id,
         scheduled_date: scheduled_date,
         duration_hours: duration_hours,
         timezone: normalize_timezone(params["timezone"]),
         recurrence_interval: recurrence_interval,
         include_booking_cover: include_booking_cover,
         family_care: family_care,
         pet_care: pet_care
       }}
    else
      {:error, {:invalid_request, message}} = error when is_binary(message) -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_create_input(params) do
    with {:ok, input} <- validate_pricing_input(params),
         {:ok, scheduled_time} <- iso_time(params["scheduledTime"]),
         {:ok, address} <- required_text(params["address"], 3, 500),
         {:ok, idempotency_key} <- optional_idempotency_key(params["idempotencyKey"]),
         {:ok, visit} <- visit_details(params),
         {:ok, legacy} <- legacy_booking_metadata(params),
         {:ok, direct_assignment} <- boolean_param(params["directAssignment"], false) do
      {:ok,
       Map.merge(input, %{
         scheduled_time: scheduled_time,
         address: address,
         special_instructions: optional_text(params["specialInstructions"], 4_000),
         idempotency_key: idempotency_key,
         direct_assignment: direct_assignment
       })
       |> Map.merge(visit)
       |> Map.merge(legacy)}
    else
      {:error, {:invalid_request, message}} = error when is_binary(message) -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp legacy_booking_metadata(params) do
    with {:ok, home_size} <- optional_legacy_home_size(params),
         {:ok, extra_task_ids} <- optional_legacy_extra_task_ids(params),
         {:ok, duration_adjustment} <- optional_legacy_duration_adjustment(params),
         {:ok, service_duration_option_id} <- optional_legacy_service_duration_option_id(params),
         {:ok, booking_source} <- optional_legacy_booking_source(params),
         {:ok, visit_duration_hours} <- optional_legacy_visit_duration_hours(params) do
      {:ok,
       %{
         home_size: home_size,
         extra_task_ids: extra_task_ids,
         duration_adjustment: duration_adjustment,
         service_duration_option_id: service_duration_option_id,
         booking_source: booking_source,
         visit_duration_hours: visit_duration_hours
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp optional_legacy_home_size(params) do
    case params do
      %{"homeSize" => value} -> {:ok, optional_text(value, 200)}
      _ -> {:ok, nil}
    end
  end

  defp optional_legacy_extra_task_ids(params) do
    case params do
      %{"extraTaskIds" => nil} ->
        {:ok, nil}

      %{"extraTaskIds" => value} when is_list(value) ->
        ids =
          value
          |> Enum.map(fn
            item when is_binary(item) -> String.trim(item)
            _ -> ""
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        if length(ids) > 32 do
          {:error, :invalid_request}
        else
          {:ok, ids}
        end

      %{"extraTaskIds" => _} ->
        {:error, :invalid_request}

      _ ->
        {:ok, nil}
    end
  end

  defp optional_legacy_duration_adjustment(params) do
    case params do
      %{"durationAdjustment" => nil} ->
        {:ok, nil}

      %{"durationAdjustment" => value} ->
        case decimal_number(value) do
          nil -> {:error, :invalid_request}
          number when number < -12 or number > 12 -> {:error, :invalid_request}
          number -> {:ok, number}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp optional_legacy_service_duration_option_id(params) do
    case params do
      %{"serviceDurationOptionId" => value} ->
        case optional_uuid(value) do
          {:ok, nil} -> {:ok, nil}
          {:ok, dumped} -> {:ok, Ecto.UUID.load!(dumped)}
          _ -> {:error, :invalid_request}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp optional_legacy_booking_source(params) do
    case params do
      %{"bookingSource" => value} -> {:ok, optional_text(value, 64)}
      _ -> {:ok, nil}
    end
  end

  defp optional_legacy_visit_duration_hours(params) do
    case params do
      %{"visitDurationHours" => nil} ->
        {:ok, nil}

      %{"visitDurationHours" => value} ->
        case positive_number(value) do
          {:ok, hours} when hours > 24 -> {:error, :invalid_request}
          {:ok, hours} -> {:ok, hours}
          :error -> {:error, :invalid_request}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp normalize_extra_task_ids(nil), do: []
  defp normalize_extra_task_ids(ids) when is_list(ids), do: ids
  defp normalize_extra_task_ids(_), do: []

  defp legacy_extra_task_ids_for_pricing(input) do
    case Map.get(input, :extra_task_ids) do
      ids when is_list(ids) and ids != [] -> ids
      _ -> nil
    end
  end

  defp legacy_extra_task_ids_for_storage(input) do
    case Map.get(input, :extra_task_ids) do
      ids when is_list(ids) and ids != [] -> ids
      _ -> nil
    end
  end

  defp legacy_service_duration_option_id(input) do
    case Map.get(input, :service_duration_option_id) do
      id when is_binary(id) and id != "" -> dump_optional_uuid(id)
      _ -> nil
    end
  end

  defp legacy_visit_duration_hours_for_pricing(input) do
    case Map.get(input, :visit_duration_hours) do
      hours when is_number(hours) and hours > 0 -> decimal_hours(hours)
      _ -> nil
    end
  end

  defp decimal_number(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_number(value) when is_integer(value), do: value * 1.0
  defp decimal_number(value) when is_float(value), do: value

  defp decimal_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp decimal_number(_), do: nil

  defp visit_details(params) do
    with {:ok, booking_for_self} <- boolean_param(params["bookingForSelf"], true),
         {:ok, requires_key} <- boolean_param(params["requiresKeyOrAccessCode"], false),
         {:ok, occupant_present} <- optional_boolean(params["occupantPresent"]),
         {:ok, property_type} <- optional_property_type(params["propertyType"]),
         {:ok, customer_contact_phone} <- optional_phone(params["customerContactPhone"]),
         {:ok, site_contact} <- site_contact(params, booking_for_self),
         {:ok, turnover} <- turnover_details(params) do
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
         site_contact_relationship: site_contact.relationship,
         turnover_guest_checkout_at: turnover.guest_checkout_at,
         turnover_next_checkin_at: turnover.next_checkin_at,
         turnover_linen_handling: turnover.linen_handling,
         turnover_restocking_notes: turnover.restocking_notes,
         turnover_source: turnover.source,
         turnover_opportunity_id: turnover.opportunity_id,
         property_id: turnover.property_id
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_reschedule_turnover(booking, schedule, pricing) do
    input =
      Map.merge(schedule, %{
        turnover_guest_checkout_at: booking.turnover_guest_checkout_at,
        turnover_next_checkin_at: booking.turnover_next_checkin_at,
        turnover_opportunity_id: booking.turnover_opportunity_id,
        property_id: booking.property_id
      })

    with :ok <- validate_turnover_window(input, pricing) do
      if is_nil(input.turnover_opportunity_id) do
        :ok
      else
        case Repo.query(
               """
               SELECT checkout_at, next_checkin_at
               FROM public.turnover_opportunities
               WHERE id = $1::uuid
                 AND ($2::uuid IS NULL OR property_id = $2::uuid)
               """,
               [input.turnover_opportunity_id, input.property_id]
             ) do
          {:ok, %{rows: [[checkout, checkin]]}} ->
            validate_window_bounds(input, pricing, checkout, checkin)

          {:ok, _} ->
            {:error, :invalid_request}

          {:error, error} ->
            database_error(error)
        end
      end
    end
  end

  defp validate_turnover_context(customer_id, input, pricing) do
    with :ok <- validate_turnover_ownership(customer_id, input),
         :ok <- validate_turnover_window(input, pricing),
         :ok <- validate_opportunity_window(customer_id, input, pricing) do
      :ok
    end
  end

  defp validate_turnover_ownership(customer_id, input) do
    property_id = Map.get(input, :property_id)
    opportunity_id = Map.get(input, :turnover_opportunity_id)

    cond do
      is_nil(property_id) and is_nil(opportunity_id) ->
        :ok

      true ->
        case Repo.query(
               """
               SELECT
                 ($2::uuid IS NULL OR EXISTS (
                   SELECT 1 FROM public.properties p
                   WHERE p.id = $2::uuid AND p.customer_id = $1::uuid
                 )),
                 ($3::uuid IS NULL OR EXISTS (
                   SELECT 1 FROM public.turnover_opportunities o
                   JOIN public.properties p ON p.id = o.property_id
                   WHERE o.id = $3::uuid
                     AND p.customer_id = $1::uuid
                     AND ($2::uuid IS NULL OR o.property_id = $2::uuid)
                 ))
               """,
               [customer_id, property_id, opportunity_id]
             ) do
          {:ok, %{rows: [[true, true]]}} -> :ok
          {:ok, %{rows: [[_, _]]}} -> {:error, :invalid_request}
          {:error, error} -> database_error(error)
        end
    end
  end

  defp validate_turnover_window(input, pricing) do
    checkout = Map.get(input, :turnover_guest_checkout_at)
    checkin = Map.get(input, :turnover_next_checkin_at)

    cond do
      is_nil(checkout) and is_nil(checkin) ->
        :ok

      not is_nil(checkout) and not is_nil(checkin) and DateTime.compare(checkout, checkin) != :lt ->
        {:error, :invalid_request}

      true ->
        start_at = scheduled_at(input.scheduled_date, input.scheduled_time, input.timezone)
        duration = pricing["durationHours"] || input.duration_hours

        with %DateTime{} = start_at <- start_at,
             {hours, _} <- Float.parse(to_string(duration)),
             true <- hours > 0,
             finish_at <- DateTime.add(start_at, round(hours * 3600), :second),
             true <- is_nil(checkout) or DateTime.compare(start_at, checkout) != :lt,
             true <- is_nil(checkin) or DateTime.compare(finish_at, checkin) != :gt do
          :ok
        else
          _ -> {:error, :invalid_request}
        end
    end
  end

  defp validate_opportunity_window(_customer_id, %{turnover_opportunity_id: nil}, _pricing),
    do: :ok

  defp validate_opportunity_window(customer_id, input, pricing) do
    case Repo.query(
           """
           SELECT o.checkout_at, o.next_checkin_at
           FROM public.turnover_opportunities o
           JOIN public.properties p ON p.id = o.property_id
           WHERE o.id = $1::uuid
             AND p.customer_id = $2::uuid
             AND ($3::uuid IS NULL OR o.property_id = $3::uuid)
           """,
           [input.turnover_opportunity_id, customer_id, input.property_id]
         ) do
      {:ok, %{rows: [[checkout, checkin]]}} ->
        validate_window_bounds(input, pricing, checkout, checkin)

      {:ok, _} ->
        {:error, :invalid_request}

      {:error, error} ->
        database_error(error)
    end
  end

  defp validate_window_bounds(input, pricing, checkout, checkin) do
    cond do
      is_nil(checkout) ->
        {:error, :invalid_request}

      not is_nil(checkin) and DateTime.compare(checkout, checkin) != :lt ->
        {:error, :invalid_request}

      true ->
        start_at = scheduled_at(input.scheduled_date, input.scheduled_time, input.timezone)
        duration = pricing["durationHours"] || input.duration_hours

        with %DateTime{} = start_at <- start_at,
             {hours, _} <- Float.parse(to_string(duration)),
             true <- hours > 0,
             finish_at <- DateTime.add(start_at, round(hours * 3600), :second),
             true <- DateTime.compare(start_at, checkout) != :lt,
             true <- is_nil(checkin) or DateTime.compare(finish_at, checkin) != :gt do
          :ok
        else
          _ -> {:error, :invalid_request}
        end
    end
  end

  defp turnover_details(params) do
    with {:ok, guest_checkout_at} <- optional_timestamptz(params["turnoverGuestCheckoutAt"]),
         {:ok, next_checkin_at} <- optional_timestamptz(params["turnoverNextCheckInAt"]),
         {:ok, linen_handling} <- optional_linen_handling(params["turnoverLinenHandling"]),
         {:ok, source} <- optional_turnover_source(params["turnoverSource"]),
         {:ok, opportunity_id} <- optional_uuid(params["turnoverOpportunityId"]),
         {:ok, property_id} <- optional_uuid(params["propertyId"]) do
      {:ok,
       %{
         guest_checkout_at: guest_checkout_at,
         next_checkin_at: next_checkin_at,
         linen_handling: linen_handling,
         restocking_notes: optional_text(params["turnoverRestockingNotes"], 2_000),
         source: source,
         opportunity_id: opportunity_id,
         property_id: property_id
       }}
    else
      _ -> :error
    end
  end

  defp optional_timestamptz(nil), do: {:ok, nil}
  defp optional_timestamptz(""), do: {:ok, nil}

  defp optional_timestamptz(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> :error
    end
  end

  defp optional_timestamptz(_), do: :error

  defp optional_linen_handling(nil), do: {:ok, nil}
  defp optional_linen_handling(""), do: {:ok, nil}

  defp optional_linen_handling(value) when is_binary(value) do
    linen = value |> String.trim() |> String.downcase()

    cond do
      linen == "" -> {:ok, nil}
      linen in @linen_handling -> {:ok, linen}
      true -> :error
    end
  end

  defp optional_linen_handling(_), do: :error

  defp optional_turnover_source(nil), do: {:ok, nil}
  defp optional_turnover_source(""), do: {:ok, nil}

  defp optional_turnover_source(value) when is_binary(value) do
    source = value |> String.trim() |> String.downcase()

    cond do
      source == "" -> {:ok, nil}
      source in @turnover_sources -> {:ok, source}
      true -> :error
    end
  end

  defp optional_turnover_source(_), do: :error

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}

  defp optional_uuid(value) when is_binary(value) do
    case value |> String.trim() |> Ecto.UUID.dump() do
      {:ok, dumped} -> {:ok, dumped}
      :error -> :error
    end
  end

  defp optional_uuid(_), do: :error

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

  @family_care_packages ~w(half_day full_day experienced negotiable)
  @family_care_frequencies ~w(once daily weekly monthly custom)

  defp optional_family_care(%{"familyCare" => nil}), do: {:ok, nil}

  defp optional_family_care(%{"familyCare" => value}) when is_map(value),
    do: parse_family_care(value)

  defp optional_family_care(%{"familyCare" => _}), do: {:error, :invalid_request}
  defp optional_family_care(_params), do: {:ok, nil}

  defp validate_family_care_visit(nil, _recurrence_interval), do: :ok

  defp validate_family_care_visit(care, recurrence_interval) do
    cond do
      care.frequency == "monthly" and care.care_package == "negotiable" ->
        {:error, {:invalid_request, "Monthly family care uses a listed package."}}

      not family_care_recurrence_matches?(care.frequency, recurrence_interval) ->
        {:error, {:invalid_request, @family_care_multiday_checkout_message}}

      not family_care_weekdays_match?(care) ->
        {:error, {:invalid_request, "Choose the days for this family care schedule."}}

      true ->
        :ok
    end
  end

  defp family_care_recurrence_matches?("once", nil), do: true

  defp family_care_recurrence_matches?("daily", interval) when interval in [nil, "daily"],
    do: true

  defp family_care_recurrence_matches?("weekly", "weekly"), do: true
  defp family_care_recurrence_matches?("custom", "weekly"), do: true
  defp family_care_recurrence_matches?("monthly", "monthly"), do: true
  defp family_care_recurrence_matches?(_frequency, _interval), do: false

  defp family_care_weekdays_match?(%{
         frequency: frequency,
         weekdays: weekdays,
         selected_day_count: count
       })
       when frequency in ["weekly", "custom"] do
    cond do
      weekdays == [] and frequency == "weekly" and count in [nil, 1, 7] -> true
      weekdays == [] and frequency == "custom" and count in [nil, 1] -> true
      is_integer(count) and length(weekdays) == count -> true
      count == nil and weekdays != [] -> true
      true -> false
    end
  end

  defp family_care_weekdays_match?(_care), do: true

  @pet_care_packages ~w(hours_2 hours_4 hours_8 overnight hours_24 custom min_30 min_60)

  defp optional_pet_care(%{"petCare" => nil}), do: {:ok, nil}

  defp optional_pet_care(%{"petCare" => value}) when is_map(value), do: parse_pet_care(value)

  defp optional_pet_care(%{"petCare" => _}), do: {:error, :invalid_request}

  defp optional_pet_care(_params), do: {:ok, nil}

  defp validate_pet_care_visit(nil, _recurrence_interval), do: :ok

  defp validate_pet_care_visit(%{frequency: "once"}, nil), do: :ok

  defp validate_pet_care_visit(_care, _recurrence_interval),
    do: {:error, {:invalid_request, "Recurring Pet Care is not available yet. Choose Just once."}}

  defp assert_pet_care_visits(%{pet_care: nil}, _pricing), do: :ok

  defp assert_pet_care_visits(%{pet_care: %{frequency: "once"}}, %{"billableDays" => 1}), do: :ok

  defp assert_pet_care_visits(%{pet_care: care}, _pricing) when is_map(care),
    do: {:error, :invalid_request}

  defp assert_pet_care_visits(_input, _pricing), do: :ok

  defp parse_pet_care(value) do
    with {:ok, care_package} <- pet_care_package(value["carePackage"]),
         {:ok, pet_count} <- pet_care_pet_count(value["petCount"]),
         {:ok, frequency} <- pet_care_frequency(value["frequency"]),
         {:ok, custom_visit_major} <- optional_non_negative_number(value["customVisitMajor"]),
         {:ok, selected_day_count} <- optional_selected_day_count(value["selectedDayCount"]),
         {:ok, extra_attention} <- boolean_param(value["extraAttention"], false),
         {:ok, medication_required} <- boolean_param(value["medicationRequired"], false) do
      {:ok,
       %{
         care_package: care_package,
         pet_count: pet_count,
         frequency: frequency,
         custom_visit_major: custom_visit_major,
         selected_day_count: selected_day_count,
         extra_attention: extra_attention,
         medication_required: medication_required
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp pet_care_package(value) when value in @pet_care_packages, do: {:ok, value}
  defp pet_care_package(_), do: :error

  defp pet_care_frequency("once"), do: {:ok, "once"}
  defp pet_care_frequency(_), do: :error

  defp pet_care_pet_count(value) when is_integer(value) and value >= 1 and value <= 20,
    do: {:ok, value}

  defp pet_care_pet_count(_), do: :error

  defp assert_family_care_visits(%{family_care: nil}, _pricing), do: :ok

  defp assert_family_care_visits(%{family_care: care} = input, pricing) do
    dates = family_care_visit_dates(care, input.scheduled_date)

    if length(dates) == pricing["billableDays"] do
      :ok
    else
      {:error, {:invalid_request, "This family care schedule does not match the quoted visits."}}
    end
  end

  defp family_care_visit_dates(care, %Date{} = anchor) do
    weekdays =
      FamilyCareSchedule.stored_weekdays(
        care.frequency,
        care.weekdays,
        anchor,
        care.selected_day_count
      )

    FamilyCareSchedule.visit_dates(
      %{"frequency" => care.frequency, "weekdays" => weekdays},
      anchor
    )
  end

  defp family_care_schedule_json(%{family_care: care} = input, pricing) when is_map(care) do
    Jason.encode!(%{
      "frequency" => care.frequency,
      "weekdays" =>
        FamilyCareSchedule.stored_weekdays(
          care.frequency,
          care.weekdays,
          input.scheduled_date,
          care.selected_day_count
        ),
      "carePackage" => care.care_package,
      "childCount" => care.child_count,
      "billableDays" => pricing["billableDays"],
      "agreedAmountMinor" => pricing["finalAmountMinor"]
    })
  end

  defp family_care_schedule_json(_input, _pricing), do: nil

  defp parse_family_care(value) do
    with {:ok, care_package} <- family_care_package(value["carePackage"]),
         {:ok, child_count} <- family_care_child_count(value["childCount"]),
         {:ok, frequency} <- family_care_frequency(value["frequency"]),
         {:ok, custom_daily_major} <- optional_non_negative_number(value["customDailyMajor"]),
         {:ok, selected_day_count} <- optional_selected_day_count(value["selectedDayCount"]),
         {:ok, weekdays} <- optional_weekdays(value["weekdays"]),
         {:ok, mobility} <- boolean_param(value["mobility"], false),
         {:ok, errands} <- boolean_param(value["errands"], false),
         {:ok, appointments} <- boolean_param(value["appointments"], false) do
      {:ok,
       %{
         care_package: care_package,
         child_count: child_count,
         frequency: frequency,
         custom_daily_major: custom_daily_major,
         selected_day_count: selected_day_count,
         weekdays: weekdays,
         mobility: mobility,
         errands: errands,
         appointments: appointments
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  @family_care_weekday_names ~w(mon tue wed thu fri sat sun)

  defp optional_weekdays(nil), do: {:ok, []}

  defp optional_weekdays(values) when is_list(values) do
    names = Enum.map(values, &to_string/1)

    if names == Enum.uniq(names) and Enum.all?(names, &(&1 in @family_care_weekday_names)) do
      {:ok, names}
    else
      :error
    end
  end

  defp optional_weekdays(_values), do: :error

  defp family_care_package(value) when value in @family_care_packages, do: {:ok, value}
  defp family_care_package(_), do: :error

  defp family_care_frequency(value) when value in @family_care_frequencies, do: {:ok, value}
  defp family_care_frequency(_), do: :error

  defp family_care_child_count(value) when is_integer(value) and value >= 1 and value <= 12,
    do: {:ok, value}

  defp family_care_child_count(_), do: :error

  defp optional_non_negative_number(nil), do: {:ok, nil}

  defp optional_non_negative_number(value) do
    case decimal_number(value) do
      number when is_number(number) and number >= 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp optional_selected_day_count(nil), do: {:ok, nil}
  defp optional_selected_day_count(0), do: {:ok, nil}

  defp optional_selected_day_count(value) when is_integer(value) and value >= 1 and value <= 7,
    do: {:ok, value}

  defp optional_selected_day_count(_), do: :error

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
