defmodule Mithril.MobileFunctions.Timezone do
  @moduledoc false

  @google_timezone_url "https://maps.googleapis.com/maps/api/timezone/json"

  @spec call(map()) :: {:ok, map()} | {:error, term()}
  def call(body) when is_map(body) do
    with {:ok, lat, lng} <- coordinates(body),
         {:ok, api_key} <- google_maps_api_key(),
         {:ok, payload} <- fetch_timezone(lat, lng, api_key) do
      {:ok, payload}
    end
  end

  defp coordinates(body) do
    lat = Map.get(body, "lat") || Map.get(body, :lat)
    lng = Map.get(body, "lng") || Map.get(body, :lng)

    with {:ok, lat_float} <- parse_coordinate(lat),
         {:ok, lng_float} <- parse_coordinate(lng) do
      {:ok, lat_float, lng_float}
    else
      _ -> {:error, {:status, 400, %{error: "Latitude and Longitude are required."}}}
    end
  end

  defp parse_coordinate(value) when is_number(value), do: {:ok, value * 1.0}

  defp parse_coordinate(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, float}
      _ -> :error
    end
  end

  defp parse_coordinate(_), do: :error

  defp google_maps_api_key do
    case Application.get_env(:mithril, :google_maps_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:status, 500, %{error: "GOOGLE_MAPS_API_KEY is not configured"}}}
    end
  end

  defp fetch_timezone(lat, lng, api_key) do
    timestamp = System.system_time(:second)

    query =
      URI.encode_query(%{
        "location" => "#{lat},#{lng}",
        "timestamp" => Integer.to_string(timestamp),
        "key" => api_key
      })

    case Req.get("#{@google_timezone_url}?#{query}") do
      {:ok, %{status: status, body: %{"status" => "OK"} = data}} when status in 200..299 ->
        {:ok, %{timezone: data["timeZoneId"], name: data["timeZoneName"]}}

      {:ok, %{status: status, body: %{"status" => status_code} = data}} when status in 200..299 ->
        {:error,
         {:status, 400,
          %{
            error: status_code,
            message: Map.get(data, "errorMessage")
          }}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:status, status, %{error: "google_timezone_error", message: inspect(body)}}}

      {:error, reason} ->
        {:error, {:status, 500, %{error: "Internal Server Error", message: inspect(reason)}}}
    end
  end
end
