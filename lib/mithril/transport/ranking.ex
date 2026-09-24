defmodule Mithril.Transport.Ranking do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.Transport.Origins
  alias Mithril.Transport.Pricing
  alias Mithril.Transport.Router

  @radius_meters 10_000
  @limit 15
  @date_regex ~r/^\d{4}-\d{2}-\d{2}$/
  @time_regex ~r/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/

  @spec for_destination(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def for_destination(_user_id, body) when is_map(body) do
    with {:ok, dest} <- destination(body),
         {:ok, fields} <- schedule_fields(body),
         {:ok, cleaner_ids} <- nearby_cleaner_ids(dest, fields),
         {:ok, origins} <- load_origins(cleaner_ids),
         {:ok, routes} <- matrix_routes(origins, dest) do
      ranked =
        origins
        |> Enum.zip(routes)
        |> Enum.map(fn {{cleaner_id, _origin}, route} ->
          priced =
            case Pricing.quote(route.distance_km) do
              {:ok, quote} -> quote
              _ -> %{amount_minor: 0, currency: "GHS"}
            end

          %{
            cleaner_id: cleaner_id,
            distance_km: route.distance_km,
            duration_seconds: route.duration_seconds,
            amount_minor: priced.amount_minor,
            currency: priced.currency
          }
        end)
        |> Enum.sort_by(fn row -> {row.duration_seconds, row.distance_km, row.cleaner_id} end)

      {:ok, %{cleaners: ranked, source: "locationiq", reason: "route_duration"}}
    end
  end

  defp destination(body) do
    lat = parse_coord(Map.get(body, "lat") || Map.get(body, "customer_latitude"))
    lng = parse_coord(Map.get(body, "lng") || Map.get(body, "customer_longitude"))

    if is_number(lat) and is_number(lng) and lat >= -90 and lat <= 90 and lng >= -180 and
         lng <= 180 do
      {:ok, %{latitude: lat, longitude: lng}}
    else
      {:error, {:status, 400, %{error: "Latitude and longitude are required"}}}
    end
  end

  defp schedule_fields(body) do
    scheduled_date = body |> Map.get("scheduled_date", "") |> to_string() |> String.trim()
    start_time = body |> Map.get("start_time", "") |> to_string() |> String.trim()
    duration_hours = Map.get(body, "duration_hours")

    cond do
      not Regex.match?(@date_regex, scheduled_date) ->
        {:error, {:status, 400, %{error: "scheduled_date must be YYYY-MM-DD"}}}

      not Regex.match?(@time_regex, start_time) ->
        {:error, {:status, 400, %{error: "start_time must be HH:mm or HH:mm:ss"}}}

      not valid_duration?(duration_hours) ->
        {:error, {:status, 400, %{error: "duration_hours must be an integer between 1 and 24"}}}

      true ->
        {:ok,
         %{
           scheduled_date: scheduled_date,
           start_time: start_time,
           duration_hours: normalize_duration(duration_hours)
         }}
    end
  end

  defp valid_duration?(value) when is_integer(value), do: value >= 1 and value <= 24
  defp valid_duration?(value) when is_float(value), do: valid_duration?(trunc(value))

  defp valid_duration?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> valid_duration?(parsed)
      :error -> false
    end
  end

  defp valid_duration?(_), do: false

  defp normalize_duration(value) when is_integer(value), do: value
  defp normalize_duration(value) when is_float(value), do: trunc(value)

  defp normalize_duration(value) when is_binary(value) do
    {parsed, _} = Integer.parse(String.trim(value))
    parsed
  end

  defp nearby_cleaner_ids(dest, fields) do
    sql = """
    SELECT id
    FROM public.get_nearby_available_cleaners($1, $2, $3, $4::date, $5::time, $6)
    """

    case Repo.query(sql, [
           dest.latitude,
           dest.longitude,
           @radius_meters,
           fields.scheduled_date,
           fields.start_time,
           fields.duration_hours
         ]) do
      {:ok, %{rows: rows}} ->
        ids =
          rows
          |> Enum.map(fn [id] -> id end)
          |> Enum.uniq()
          |> Enum.take(@limit)

        {:ok, ids}

      _ ->
        {:ok, []}
    end
  end

  defp load_origins(cleaner_ids) do
    origins =
      Enum.reduce(cleaner_ids, [], fn cleaner_id, acc ->
        case Origins.load_cleaner_origin(cleaner_id) do
          {:ok, origin} -> [{cleaner_id, origin} | acc]
          _ -> acc
        end
      end)

    {:ok, Enum.reverse(origins)}
  end

  defp matrix_routes([], _dest), do: {:ok, []}

  defp matrix_routes(origins, dest) do
    coords = Enum.map(origins, fn {_id, origin} -> origin end)

    case Router.matrix(coords, dest) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           %{
             distance_km: Float.round((row.distance_m || 0) / 1000.0, 2),
             duration_seconds: max(0, trunc(row.duration_s || 0))
           }
         end)}

      {:error, :not_configured} ->
        {:error, {:status, 500, %{error: "Transport routing is not configured"}}}

      _ ->
        {:error, {:status, 502, %{error: "Could not rank cleaners by route"}}}
    end
  end

  defp parse_coord(value) when is_integer(value), do: value * 1.0
  defp parse_coord(value) when is_float(value), do: value

  defp parse_coord(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_coord(_), do: nil
end
