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

  def list_services do
    # `service_types.duration` is a display string like "2 hours", so it cannot
    # be coalesced with numeric hour columns.
    case Repo.query("""
         SELECT jsonb_build_object(
           'id', id,
           'name', name,
           'priceGhs', price,
           'minimumDurationHours', COALESCE(minimum_duration_hours, 2),
           'maximumDurationHours', COALESCE(maximum_duration_hours, 12),
           'durationIncrementHours', COALESCE(duration_increment_hours, 0.5),
           'specialtySlug', specialty_slug
         )
         FROM public.service_types
         WHERE active = true
         ORDER BY name ASC
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

  def create_booking(user_id, params) when is_map(params) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, input} <- validate_create_input(params) do
      Repo.transaction(fn ->
        with {:ok, service} <- service_details(input.service_id),
             :ok <- cleaner_eligible(input.cleaner_id, service.specialty_slug),
             {:ok, pricing} <- compute_pricing(input),
             :ok <- validate_timeslot(input, pricing),
             {:ok, booking_id} <- insert_booking(customer_id, input, pricing, service.name) do
          %{
            id: booking_id,
            status: "pending",
            paymentStatus: "pending",
            amountMinor: pricing["finalAmountMinor"],
            currency: pricing["currency"] || "GHS"
          }
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

  def get_booking(user_id, booking_id) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT jsonb_build_object(
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
             'cleanerEarningsMinor', p.cleaner_earnings_minor
           )
           FROM public.compute_booking_pricing(
             p_service_id => $1::integer,
             p_duration_hours_raw => $2::numeric,
             p_scheduled_date => $3::date,
             p_service_timezone => $4::text,
             p_recurrence_interval => NULL,
             p_is_recurring => false,
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
             input.cleaner_id
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

  defp insert_booking(customer_id, input, pricing, service_name) do
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
             timezone
           ) VALUES (
             $1, $2, $3, $4, $5::date, $6::time, $7, $7, $8,
             NULLIF($9::text, ''), $10::numeric, $11::integer, $12::integer,
             $13::integer, $14::integer, $15::integer,
             $16, $17, $18, $19, $20, 0, true, $21, $22, $23,
             $24::integer, $25::integer, 'pending', 'pending', $26
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
             input.timezone
           ]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:error, error} -> database_error(error)
    end
  end

  defp validate_pricing_input(params) do
    with {:ok, service_id} <- positive_integer(params["serviceId"]),
         {:ok, cleaner_id} <- required_uuid(params["cleanerId"]),
         {:ok, scheduled_date} <- iso_date(params["scheduledDate"]),
         {:ok, duration_hours} <- positive_number(params["durationHours"]) do
      {:ok,
       %{
         service_id: service_id,
         cleaner_id: cleaner_id,
         scheduled_date: scheduled_date,
         duration_hours: duration_hours,
         timezone: normalize_timezone(params["timezone"])
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_create_input(params) do
    with {:ok, input} <- validate_pricing_input(params),
         {:ok, scheduled_time} <- iso_time(params["scheduledTime"]),
         {:ok, address} <- required_text(params["address"], 3, 500) do
      {:ok,
       Map.merge(input, %{
         scheduled_time: scheduled_time,
         address: address,
         special_instructions: optional_text(params["specialInstructions"], 4_000)
       })}
    else
      _ -> {:error, :invalid_request}
    end
  end

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

  defp decimal_hours(%Decimal{} = value), do: value
  defp decimal_hours(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_hours(value) when is_float(value), do: Decimal.from_float(value)

  defp format_hhmm(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp database_error(error) do
    Logger.error("Direct bookings database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
