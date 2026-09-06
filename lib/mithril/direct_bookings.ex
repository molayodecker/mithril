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
    case Repo.query("""
         SELECT jsonb_build_object(
           'id', id,
           'name', name,
           'priceGhs', price,
           'minimumDurationHours', COALESCE(minimum_duration_hours, duration, 2),
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

  def list_cleaners do
    case Repo.query("""
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
         ORDER BY COALESCE(cd.rating, 0) DESC,
                  COALESCE(cd.completed_jobs, 0) DESC
         LIMIT 100
         """) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  def preview_price(params) when is_map(params) do
    with {:ok, input} <- validate_pricing_input(params),
         {:ok, pricing} <- compute_pricing(input) do
      {:ok, pricing}
    end
  end

  def create_booking(user_id, params) when is_map(params) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, input} <- validate_create_input(params) do
      Repo.transaction(fn ->
        with {:ok, pricing} <- compute_pricing(input),
             {:ok, service_name} <- service_name(input.service_id),
             {:ok, booking_id} <- insert_booking(customer_id, input, pricing, service_name) do
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
             p_cleaner_id => $5::uuid,
             p_is_recurring => false,
             p_include_booking_cover => true,
             p_supplies_option => 'customer_provided'
           ) p
           """,
           [
             input.service_id,
             input.duration_hours,
             Date.to_iso8601(input.scheduled_date),
             input.timezone,
             input.cleaner_id
           ]
         ) do
      {:ok, %{rows: [[pricing]]}} -> {:ok, pricing}
      {:ok, %{rows: []}} -> {:error, :pricing_unavailable}
      {:error, error} ->
        Logger.warning("Direct booking pricing failed: #{inspect(error)}")
        {:error, :pricing_unavailable}
    end
  end

  defp service_name(service_id) do
    case Repo.query(
           "SELECT name FROM public.service_types WHERE id = $1 AND active = true LIMIT 1",
           [service_id]
         ) do
      {:ok, %{rows: [[name]]}} -> {:ok, name}
      {:ok, %{rows: []}} -> {:error, :invalid_service}
      {:error, error} -> database_error(error)
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
             NULLIF($9::text, ''), $10, $10, $11, $12, $13, $14,
             $15, $16, $17, $18, $19, 0, true, $20, $21, $22,
             $23, $24, 'pending', 'pending', $25
           )
           RETURNING id::text
           """,
           [
             customer_id,
             input.cleaner_id,
             input.service_id,
             service_name,
             Date.to_iso8601(input.scheduled_date),
             Time.to_iso8601(input.scheduled_time),
             pricing["durationHours"],
             input.address,
             input.special_instructions || "",
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
  defp optional_text(value, max) when is_binary(value), do: value |> String.trim() |> String.slice(0, max)
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

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp database_error(error) do
    Logger.error("Direct bookings database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
