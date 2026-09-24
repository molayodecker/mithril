defmodule Mithril.Transport.Router.LocationIQ do
  @moduledoc false

  @behaviour Mithril.Transport.Router

  @impl true
  def directions(from, to) do
    with {:ok, key} <- access_token() do
      coords = encode_pair(from) <> ";" <> encode_pair(to)
      url = "#{base_url()}/directions/driving/#{coords}"

      case get(url, %{"key" => key, "overview" => "false"}) do
        {:ok, body} -> parse_directions(body)
        error -> error
      end
    end
  end

  @impl true
  def matrix([], _dest), do: {:ok, []}

  def matrix(sources, dest) when is_list(sources) do
    with {:ok, key} <- access_token() do
      points = sources ++ [dest]
      coords = Enum.map_join(points, ";", &encode_pair/1)
      last = length(sources)
      source_idx = 0..(last - 1) |> Enum.map_join(";", &Integer.to_string/1)

      url = "#{base_url()}/matrix/driving/#{coords}"

      query = %{
        "key" => key,
        "sources" => source_idx,
        "destinations" => Integer.to_string(last),
        "annotations" => "distance,duration"
      }

      case get(url, query) do
        {:ok, body} -> parse_matrix(body, length(sources))
        error -> error
      end
    end
  end

  @impl true
  def geocode(address) when is_binary(address) do
    query = String.trim(address)

    cond do
      query == "" ->
        {:error, :not_found}

      true ->
        with {:ok, key} <- access_token() do
          url = "#{base_url()}/search"

          case get(url, %{"key" => key, "q" => query, "format" => "json", "limit" => "1"}) do
            {:ok, body} -> parse_geocode(body)
            error -> error
          end
        end
    end
  end

  @doc false
  def parse_directions_fixture(body), do: parse_directions(body)

  defp get(url, query) do
    case Req.get(url, params: query, receive_timeout: 8_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :not_configured}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} when status in 400..499 ->
        {:error, :route_unavailable}

      _ ->
        {:error, :provider_unavailable}
    end
  end

  defp parse_directions(%{"code" => code, "routes" => [route | _]}) when code in ["Ok", "ok"] do
    distance = to_float(Map.get(route, "distance"))
    duration = to_float(Map.get(route, "duration"))

    if distance && duration && distance >= 0 do
      {:ok, %{distance_m: distance, duration_s: duration}}
    else
      {:error, :route_unavailable}
    end
  end

  defp parse_directions(_), do: {:error, :route_unavailable}

  defp parse_matrix(body, expected) when is_map(body) do
    distances = Map.get(body, "distances")
    durations = Map.get(body, "durations")

    cond do
      is_list(distances) and is_list(durations) and length(distances) == expected ->
        rows =
          Enum.zip(distances, durations)
          |> Enum.map(fn {distance_row, duration_row} ->
            distance = row_value(distance_row)
            duration = row_value(duration_row)

            if is_number(distance) and is_number(duration) do
              %{distance_m: distance, duration_s: duration}
            else
              nil
            end
          end)

        {:ok, rows}

      true ->
        {:error, :route_unavailable}
    end
  end

  defp parse_matrix(_, _), do: {:error, :route_unavailable}

  defp parse_geocode([%{"lat" => lat, "lon" => lon} | _]) do
    with lat_f when not is_nil(lat_f) <- to_float(lat),
         lng_f when not is_nil(lng_f) <- to_float(lon) do
      {:ok, %{latitude: lat_f, longitude: lng_f}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_geocode(_), do: {:error, :not_found}

  defp row_value([value | _]), do: to_float(value)
  defp row_value(value), do: to_float(value)

  defp encode_pair(%{longitude: lng, latitude: lat}), do: "#{lng},#{lat}"

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp to_float(_), do: nil

  defp access_token do
    case Application.get_env(:mithril, :locationiq_access_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_configured}
    end
  end

  defp base_url do
    Application.get_env(:mithril, :locationiq_base_url, "https://us1.locationiq.com/v1")
    |> to_string()
    |> String.trim_trailing("/")
  end
end
