defmodule Mithril.DirectAdminDispatchMap do
  @moduledoc "Staff dispatch map: cleaner locations and upcoming customer bookings."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  @statuses ~w(pending confirmed scheduled en_route arrived in_progress)

  def load(user_id, params \\ %{}) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, filters} <- validate_filters(params) do
      cleaners = load_cleaners()
      bookings = load_bookings(filters)
      {:ok, %{"cleaners" => cleaners, "customerBookings" => bookings}}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_cleaners do
    case rpc_rows("SELECT to_jsonb(t) FROM public.get_admin_cleaner_dispatch_map() t") do
      {:ok, rows} -> Enum.map(rows, &normalize_cleaner/1) |> Enum.reject(&is_nil/1)
      {:error, _} -> fallback_cleaners()
    end
  end

  defp load_bookings(filters) do
    case Repo.query(
           """
           SELECT to_jsonb(t)
           FROM public.get_admin_customer_dispatch_locations(
             p_days_ahead := $1::integer,
             p_statuses := $2::text[]
           ) t
           """,
           [filters.days_ahead, filters.statuses]
         ) do
      {:ok, result} ->
        result.rows
        |> Enum.map(&hd/1)
        |> Enum.map(&normalize_booking/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        fallback_bookings(filters)
    end
  end

  defp fallback_cleaners do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'userId', cd.user_id,
             'displayName', COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               'Cleaner'
             ),
             'latitude', CASE
               WHEN cd.base_location IS NULL THEN NULL
               ELSE ST_Y(cd.base_location::geometry)
             END,
             'longitude', CASE
               WHEN cd.base_location IS NULL THEN NULL
               ELSE ST_X(cd.base_location::geometry)
             END,
             'maxTravelDistanceMeters', COALESCE(cd.max_travel_distance_meters, 30000),
             'specialties', COALESCE(cd.specialties, '{}'::text[]),
             'serviceAreas', COALESCE(cd.service_areas, '{}'::text[]),
             'rating', cd.rating,
             'completedJobs', cd.completed_jobs,
             'verified', COALESCE(cd.verified, false),
             'status', COALESCE(cd.status::text, 'active')
           )
           FROM public.cleaner_data cd
           LEFT JOIN public.profiles p ON p.id = cd.user_id
           WHERE COALESCE(cd.status::text, 'active') = 'active'
           LIMIT 400
           """
         ) do
      {:ok, result} -> Enum.map(result.rows, &hd/1)
      {:error, error} ->
        Logger.error("Direct admin dispatch map cleaner fallback failed: #{inspect(error)}")
        []
    end
  end

  defp fallback_bookings(filters) do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'bookingId', b.id,
             'customerId', b.customer_id,
             'customerName', COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               'Customer'
             ),
             'address', COALESCE(b.address, ''),
             'latitude', coord.lat,
             'longitude', coord.lng,
             'scheduledAtUtc', b.scheduled_at_utc,
             'timezoneName', COALESCE(NULLIF(b.timezone, ''), 'Africa/Accra'),
             'status', b.status::text,
             'serviceName', COALESCE(st.name, 'Service'),
             'cleanerId', b.cleaner_id
           )
           FROM public.bookings b
           JOIN public.service_types st ON st.id = b.service_id
           LEFT JOIN public.profiles p ON p.id = b.customer_id
           CROSS JOIN LATERAL (
             SELECT
               COALESCE(
                 NULLIF(b.location_coordinates::jsonb->>'latitude', '')::float,
                 NULLIF(b.location_coordinates::jsonb->>'lat', '')::float,
                 CASE WHEN geometrytype(b.location_coordinates::geometry) IS NOT NULL
                      THEN ST_Y(b.location_coordinates::geometry) END
               ) AS lat,
               COALESCE(
                 NULLIF(b.location_coordinates::jsonb->>'longitude', '')::float,
                 NULLIF(b.location_coordinates::jsonb->>'lng', '')::float,
                 CASE WHEN geometrytype(b.location_coordinates::geometry) IS NOT NULL
                      THEN ST_X(b.location_coordinates::geometry) END
               ) AS lng
           ) coord
           WHERE b.status::text = ANY($1::text[])
             AND b.scheduled_date <= (CURRENT_DATE + ($2::integer || ' days')::interval)
             AND coord.lat IS NOT NULL
             AND coord.lng IS NOT NULL
           ORDER BY b.scheduled_date ASC, b.scheduled_time ASC NULLS LAST
           LIMIT 400
           """,
           [filters.statuses, filters.days_ahead]
         ) do
      {:ok, result} -> Enum.map(result.rows, &hd/1)
      {:error, error} ->
        Logger.error("Direct admin dispatch map booking fallback failed: #{inspect(error)}")
        []
    end
  end

  defp rpc_rows(sql) do
    case Repo.query(sql) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_cleaner(row) when is_map(row) do
    user_id = str(row["userId"] || row["user_id"])
    if user_id == "" do
      nil
    else
      lat = num(row["latitude"])
      lng = num(row["longitude"])

      %{
        "userId" => user_id,
        "displayName" => str(row["displayName"] || row["display_name"]) || "Cleaner",
        "latitude" => lat,
        "longitude" => lng,
        "maxTravelDistanceMeters" => trunc(num(row["maxTravelDistanceMeters"] || row["max_travel_distance_meters"]) || 30_000),
        "specialties" => list(row["specialties"]),
        "serviceAreas" => list(row["serviceAreas"] || row["service_areas"]),
        "rating" => num(row["rating"]),
        "completedJobs" => num(row["completedJobs"] || row["completed_jobs"]),
        "verified" => row["verified"] == true,
        "status" => str(row["status"]) || "active"
      }
    end
  end

  defp normalize_cleaner(_), do: nil

  defp normalize_booking(row) when is_map(row) do
    booking_id = str(row["bookingId"] || row["booking_id"])
    customer_id = str(row["customerId"] || row["customer_id"])
    lat = num(row["latitude"])
    lng = num(row["longitude"])

    if booking_id == "" or customer_id == "" or lat == nil or lng == nil do
      nil
    else
      %{
        "bookingId" => booking_id,
        "customerId" => customer_id,
        "customerName" => str(row["customerName"] || row["customer_name"]) || "Customer",
        "address" => str(row["address"]) || "",
        "latitude" => lat,
        "longitude" => lng,
        "scheduledAtUtc" => row["scheduledAtUtc"] || row["scheduled_at_utc"],
        "timezoneName" => str(row["timezoneName"] || row["timezone_name"]) || "Africa/Accra",
        "status" => str(row["status"]) || "scheduled",
        "serviceName" => str(row["serviceName"] || row["service_name"]) || "Service",
        "cleanerId" => empty_to_nil(str(row["cleanerId"] || row["cleaner_id"]))
      }
    end
  end

  defp normalize_booking(_), do: nil

  defp validate_filters(params) do
    statuses =
      (params["statuses"] || params[:statuses] || @statuses)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 in @statuses))
      |> Enum.uniq()

    statuses = if statuses == [], do: @statuses, else: statuses
    days = clamp_days(params["daysAhead"] || params[:daysAhead])
    {:ok, %{statuses: statuses, days_ahead: days}}
  end

  defp clamp_days(value) when is_integer(value), do: min(90, max(1, value))

  defp clamp_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> clamp_days(n)
      _ -> 30
    end
  end

  defp clamp_days(_), do: 30

  defp str(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp str(_), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp num(value) when is_integer(value), do: value * 1.0
  defp num(value) when is_float(value) and value == value, do: value
  defp num(%Decimal{} = value), do: Decimal.to_float(value)

  defp num(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp num(_), do: nil

  defp list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp list(_), do: []

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error
end

