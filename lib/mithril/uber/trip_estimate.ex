defmodule Mithril.Uber.TripEstimate do
  @moduledoc false

  alias Mithril.Repo

  @auth_url "https://auth.uber.com/oauth/v2/token"
  @api_base "https://api.uber.com"
  @default_scope "ride_request.estimate"
  @miles_to_km 1.60934
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @spec parse_request(map()) :: {:ok, map()} | {:error, String.t()}
  def parse_request(body) when is_map(body) do
    with {:ok, cleaner_id} <- parse_cleaner_id(Map.get(body, "cleaner_id")),
         {:ok, customer_latitude} <- parse_coordinate(Map.get(body, "customer_latitude"), -90, 90),
         {:ok, customer_longitude} <-
           parse_coordinate(Map.get(body, "customer_longitude"), -180, 180) do
      {:ok,
       %{
         cleaner_id: cleaner_id,
         customer_latitude: customer_latitude,
         customer_longitude: customer_longitude
       }}
    end
  end

  def parse_request(_), do: {:error, "Invalid JSON body"}

  @spec fetch_estimate(map()) :: {:ok, map()} | {:error, String.t()}
  def fetch_estimate(input) when is_map(input) do
    with {:ok, token} <- access_token(),
         {:ok, products} <- price_products(token, input),
         {:ok, product} <- pick_product(products) do
      {:ok, map_product(product)}
    end
  end

  @spec load_cleaner_origin(String.t()) :: {:ok, map()} | {:error, atom()}
  def load_cleaner_origin(cleaner_id) do
    case Repo.query("SELECT * FROM public.get_cleaner_trip_origin($1::uuid)", [cleaner_id]) do
      {:ok, %{columns: columns, rows: [row]}} ->
        row_map = Map.new(Enum.zip(columns, row))
        lat = parse_float(Map.get(row_map, "latitude"))
        lng = parse_float(Map.get(row_map, "longitude"))

        if lat != nil and lng != nil do
          {:ok, %{latitude: lat, longitude: lng}}
        else
          {:error, :missing}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp parse_cleaner_id(value) do
    cleaner_id = value |> to_string() |> String.trim()

    if Regex.match?(@uuid_regex, cleaner_id) do
      {:ok, cleaner_id}
    else
      {:error, "cleaner_id must be a valid UUID"}
    end
  end

  defp parse_coordinate(value, min, max) do
    coordinate = parse_float(value)

    cond do
      coordinate == nil -> {:error, "Coordinate must be a number"}
      coordinate < min or coordinate > max -> {:error, "Coordinate is out of range"}
      true -> {:ok, coordinate}
    end
  end

  defp parse_float(value) when is_integer(value), do: value * 1.0
  defp parse_float(value) when is_float(value), do: value

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp access_token do
    cache = :persistent_term.get({__MODULE__, :token}, nil)
    now_ms = System.system_time(:millisecond)

    if cache && Map.get(cache, :expires_at_ms, 0) > now_ms + 30_000 do
      {:ok, cache.token}
    else
      client_id = env("UBER_CLIENT_ID")
      client_secret = env("UBER_CLIENT_SECRET")

      if client_id == "" or client_secret == "" do
        {:error, "Uber credentials are not configured"}
      else
        scope = env("UBER_ESTIMATE_SCOPE", @default_scope)

        body =
          URI.encode_query(%{
            "client_id" => client_id,
            "client_secret" => client_secret,
            "grant_type" => "client_credentials",
            "scope" => scope
          })

        case Req.post(@auth_url,
               headers: [{"content-type", "application/x-www-form-urlencoded"}],
               body: body
             ) do
          {:ok, %{status: status, body: payload}} when status in 200..299 and is_map(payload) ->
            token = Map.get(payload, "access_token") |> to_string()

            if token == "" do
              {:error, "Uber auth did not return an access token"}
            else
              expires_in = Map.get(payload, "expires_in") |> parse_float() || 3600

              :persistent_term.put(
                {__MODULE__, :token},
                %{token: token, expires_at_ms: now_ms + trunc(expires_in * 1000)}
              )

              {:ok, token}
            end

          {:ok, %{body: payload}} when is_map(payload) ->
            {:error, Map.get(payload, "error_description", "Uber auth failed") |> to_string()}

          _ ->
            {:error, "Uber auth failed"}
        end
      end
    end
  end

  defp price_products(token, input) do
    query =
      URI.encode_query(%{
        "start_latitude" => input.cleaner_latitude,
        "start_longitude" => input.cleaner_longitude,
        "end_latitude" => input.customer_latitude,
        "end_longitude" => input.customer_longitude
      })

    case Req.get("#{@api_base}/v1.2/estimates/price?#{query}",
           headers: [
             {"authorization", "Bearer #{token}"},
             {"accept-language", "en_US"},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %{status: status, body: payload}} when status in 200..299 and is_map(payload) ->
        products = Map.get(payload, "prices") || []
        {:ok, if(is_list(products), do: products, else: [])}

      {:ok, %{body: payload}} when is_map(payload) ->
        {:error, Map.get(payload, "message", "Uber price estimate failed") |> to_string()}

      _ ->
        {:error, "Uber price estimate failed"}
    end
  end

  defp pick_product([]), do: {:error, "Uber did not return a price estimate for this route"}

  defp pick_product(products) do
    preferred = ["uberx", "uber go", "go"]

    normalized =
      Enum.map(products, fn product ->
        name =
          product
          |> Map.get("localized_display_name", Map.get(product, "display_name", ""))
          |> to_string()
          |> String.downcase()

        {product, name}
      end)

    match =
      Enum.find_value(preferred, fn preferred_name ->
        Enum.find(normalized, fn {_product, name} -> String.contains?(name, preferred_name) end)
      end)

    case match || List.first(normalized) do
      {product, _} -> {:ok, product}
      _ -> {:error, "Uber did not return a price estimate for this route"}
    end
  end

  defp map_product(product) when is_map(product) do
    distance_miles = parse_float(Map.get(product, "distance"))
    duration_seconds = parse_float(Map.get(product, "duration"))
    low_estimate = parse_float(Map.get(product, "low_estimate"))
    high_estimate = parse_float(Map.get(product, "high_estimate"))

    if distance_miles == nil or distance_miles <= 0 do
      raise ArgumentError, "Uber estimate did not include trip distance"
    end

    low_estimate_major = if low_estimate && low_estimate > 0, do: low_estimate, else: nil
    high_estimate_major = if high_estimate && high_estimate > 0, do: high_estimate, else: nil

    %{
      distance_km: Float.round(distance_miles * @miles_to_km, 2),
      distance_miles: Float.round(distance_miles, 2),
      duration_seconds:
        if(duration_seconds && duration_seconds > 0, do: trunc(duration_seconds), else: 0),
      currency_code: Map.get(product, "currency_code", "USD") |> to_string() |> String.trim(),
      estimate_display: Map.get(product, "estimate", "") |> to_string() |> String.trim(),
      low_estimate_major: low_estimate_major,
      high_estimate_major: high_estimate_major,
      customer_fee_major: high_estimate_major || low_estimate_major,
      product_id: Map.get(product, "product_id", "") |> to_string() |> String.trim(),
      product_name:
        Map.get(product, "localized_display_name", Map.get(product, "display_name", ""))
        |> to_string()
        |> String.trim()
    }
  end

  defp env(name, default \\ "") do
    case System.get_env(name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end
end
