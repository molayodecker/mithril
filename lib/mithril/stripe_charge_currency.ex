defmodule Mithril.StripeChargeCurrency do
  @moduledoc false

  @booking_source_currency "ghs"
  @presentment_currency "usd"
  @usd_minimum_minor 50
  @rate_scale 1_000_000

  @spec presentment_charge(map()) :: {:ok, map()} | {:error, String.t()}
  def presentment_charge(params) when is_map(params) do
    booking_amount_minor = positive_minor(params[:booking_amount_minor] || params["booking_amount_minor"])
    booking_currency =
      (params[:booking_currency] || params["booking_currency"] || @booking_source_currency)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    usd_per_ghs = params[:usd_per_ghs] || params["usd_per_ghs"]

    cond do
      is_nil(booking_amount_minor) ->
        {:error, "Booking has no payable amount"}

      booking_currency == @presentment_currency ->
        if booking_amount_minor < @usd_minimum_minor do
          {:error, "Amount is too small for card checkout. Please pay with Mobile Money."}
        else
          {:ok,
           %{
             amount_minor: booking_amount_minor,
             currency: @presentment_currency,
             source_amount_minor: booking_amount_minor,
             source_currency: booking_currency
           }}
        end

      booking_currency == @booking_source_currency ->
        with {:ok, converted} <- convert_ghs_minor(booking_amount_minor, usd_per_ghs) do
          if converted < @usd_minimum_minor do
            {:error, "Amount is too small for card checkout. Please pay with Mobile Money."}
          else
            {:ok,
             %{
               amount_minor: converted,
               currency: @presentment_currency,
               source_amount_minor: booking_amount_minor,
               source_currency: booking_currency,
               usd_per_ghs: usd_per_ghs
             }}
          end
        end

      true ->
        {:error, "Card checkout does not support this booking currency. Please use another payment method."}
    end
  end

  @spec fetch_ghs_to_usd_rate(keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_ghs_to_usd_rate(opts \\ []) do
    secret_key = Keyword.get(opts, :secret_key, stripe_secret_key())
    api_url = Keyword.get(opts, :api_url, "https://api.stripe.com/v1")
    public_rate_url = Keyword.get(opts, :public_rate_url, "https://open.er-api.com/v6/latest/GHS")

    case fx_quotes_rate(secret_key, api_url) do
      {:ok, quote} ->
        {:ok, quote}

      {:error, _} ->
        case exchange_rates_fallback(secret_key, api_url) do
          {:ok, quote} ->
            {:ok, quote}

          {:error, _} ->
            case public_mid_market_rate(public_rate_url) do
              {:ok, rate} ->
                {:ok, %{usd_per_ghs: rate, quote_id: nil, source: "live_mid_market"}}

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  @spec user_facing_init_error(String.t()) :: String.t()
  def user_facing_init_error(message) when is_binary(message) do
    if Regex.match?(~r/invalid currency|do not support/i, message) do
      "Card checkout is not available for this booking. Please pay with Mobile Money."
    else
      message
    end
  end

  defp convert_ghs_minor(source_minor, usd_per_ghs) do
    rate = if is_number(usd_per_ghs), do: usd_per_ghs, else: nil

    cond do
      is_nil(rate) or rate <= 0 ->
        {:error, "Exchange rate is unavailable"}

      true ->
        scaled_rate = round(rate * @rate_scale)

        if scaled_rate <= 0 do
          {:error, "Exchange rate is unavailable"}
        else
          converted =
            div(source_minor * scaled_rate + div(@rate_scale, 2), @rate_scale)

          if converted > 0, do: {:ok, converted}, else: {:error, "Converted amount is invalid"}
        end
    end
  end

  defp fx_quotes_rate("", _api_url), do: {:error, :missing_secret}

  defp fx_quotes_rate(secret_key, api_url) do
    body =
      URI.encode_query(%{
        "to_currency" => @presentment_currency,
        "from_currencies[]" => @booking_source_currency,
        "lock_duration" => "none",
        "usage[type]" => "payment"
      })

    case stripe_post("#{api_url}/fx_quotes", secret_key, body,
           stripe_version: "2025-07-30.preview"
         ) do
      {:ok, payload} ->
        rate = get_in(payload, ["rates", "ghs", "exchange_rate"]) |> positive_rate()

        if rate do
          {:ok,
           %{
             usd_per_ghs: rate,
             quote_id: payload["id"],
             source: "fx_quotes"
           }}
        else
          {:error, :fx_quotes_unavailable}
        end

      {:error, _} ->
        {:error, :fx_quotes_unavailable}
    end
  end

  defp exchange_rates_fallback("", _api_url), do: {:error, :missing_secret}

  defp exchange_rates_fallback(secret_key, api_url) do
    case stripe_get("#{api_url}/exchange_rates/usd", secret_key) do
      {:ok, payload} ->
        ghs_per_usd = get_in(payload, ["rates", "ghs"]) |> positive_rate()

        if ghs_per_usd do
          {:ok, %{usd_per_ghs: 1 / ghs_per_usd, quote_id: nil, source: "exchange_rates"}}
        else
          {:error, :exchange_rates_unavailable}
        end

      {:error, _} ->
        {:error, :exchange_rates_unavailable}
    end
  end

  defp public_mid_market_rate(url) do
    case Req.get(url, receive_timeout: 8_000) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        rate =
          (get_in(payload, ["rates", "USD"]) || get_in(payload, ["rates", "usd"]))
          |> positive_rate()

        if rate, do: {:ok, rate}, else: {:error, :public_rate_unavailable}

      _ ->
        {:error, :public_rate_unavailable}
    end
  end

  defp stripe_get(url, secret_key) do
    case Req.get(url, auth: {:bearer, secret_key}, receive_timeout: 8_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      _ ->
        {:error, :stripe_http}
    end
  end

  defp stripe_post(url, secret_key, body, opts) do
    headers =
      [{"content-type", "application/x-www-form-urlencoded"}]
      |> maybe_stripe_version(Keyword.get(opts, :stripe_version))

    case Req.post(url,
           auth: {:bearer, secret_key},
           body: body,
           headers: headers,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: status, body: payload}} when status in 200..299 and is_map(payload) ->
        {:ok, payload}

      _ ->
        {:error, :stripe_http}
    end
  end

  defp maybe_stripe_version(headers, nil), do: headers

  defp maybe_stripe_version(headers, version),
    do: [{"stripe-version", version} | headers]

  defp positive_minor(value) when is_integer(value) and value > 0, do: value

  defp positive_minor(value) when is_float(value) do
    rounded = round(value)
    if abs(value - rounded) <= 1.0e-6 and rounded > 0, do: rounded
  end

  defp positive_minor(%Decimal{} = value) do
    if Decimal.compare(value, 0) == :gt, do: Decimal.to_integer(value)
  end

  defp positive_minor(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_minor(_), do: nil

  defp positive_rate(value) when is_number(value) and value > 0, do: value * 1.0
  defp positive_rate(_), do: nil

  defp stripe_secret_key do
    Application.get_env(:mithril, :stripe_secret_key, "")
    |> to_string()
    |> String.trim()
  end
end
