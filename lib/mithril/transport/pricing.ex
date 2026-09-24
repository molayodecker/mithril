defmodule Mithril.Transport.Pricing do
  @moduledoc false

  alias Mithril.Repo

  @defaults %{
    currency: "GHS",
    base_fee_minor: 1_000,
    per_km_rate_minor: 350,
    min_fee_minor: 1_500,
    max_fee_minor: 15_000,
    bands: []
  }

  @spec quote(number()) :: {:ok, map()} | {:error, term()}
  def quote(distance_km) when is_number(distance_km) and distance_km >= 0 do
    rules = load_rules()
    amount = amount_minor(distance_km, rules)

    {:ok,
     %{
       distance_km: Float.round(distance_km * 1.0, 2),
       amount_minor: amount,
       currency: rules.currency
     }}
  end

  def quote(_), do: {:error, :invalid_distance}

  defp amount_minor(distance_km, rules) do
    band = matching_band(distance_km, rules.bands)

    base = (band && Map.get(band, :base_fee_minor)) || rules.base_fee_minor
    rate = (band && Map.get(band, :per_km_rate_minor)) || rules.per_km_rate_minor
    raw = trunc(base + distance_km * rate)

    raw
    |> max(rules.min_fee_minor)
    |> min(rules.max_fee_minor)
    |> max(0)
  end

  defp matching_band(distance_km, bands) when is_list(bands) do
    Enum.find(bands, fn band ->
      min_km = Map.get(band, :min_km) || 0
      max_km = Map.get(band, :max_km)
      distance_km >= min_km and (is_nil(max_km) or distance_km < max_km)
    end)
  end

  defp matching_band(_, _), do: nil

  defp load_rules do
    sql = """
    SELECT currency, base_fee_minor, per_km_rate_minor, min_fee_minor, max_fee_minor, bands
    FROM public.transport_pricing_rules
    WHERE enabled = true
    ORDER BY CASE WHEN channel = 'production' THEN 0 ELSE 1 END, updated_at DESC
    LIMIT 1
    """

    case Repo.query(sql, []) do
      {:ok, %{rows: [[currency, base, per_km, min_fee, max_fee, bands]]}} ->
        %{
          currency: present(currency) || @defaults.currency,
          base_fee_minor: to_int(base, @defaults.base_fee_minor),
          per_km_rate_minor: to_int(per_km, @defaults.per_km_rate_minor),
          min_fee_minor: to_int(min_fee, @defaults.min_fee_minor),
          max_fee_minor: to_int(max_fee, @defaults.max_fee_minor),
          bands: parse_bands(bands)
        }

      _ ->
        @defaults
    end
  end

  defp parse_bands(bands) when is_list(bands), do: Enum.flat_map(bands, &parse_band/1)
  defp parse_bands(bands) when is_binary(bands), do: bands |> decode_json() |> parse_bands()
  defp parse_bands(_), do: []

  defp parse_band(band) when is_map(band) do
    min_km = to_float(Map.get(band, "min_km") || Map.get(band, :min_km) || 0)
    max_km = to_float(Map.get(band, "max_km") || Map.get(band, :max_km))

    [
      %{
        min_km: min_km || 0.0,
        max_km: max_km,
        base_fee_minor:
          to_int(Map.get(band, "base_fee_minor") || Map.get(band, :base_fee_minor), nil),
        per_km_rate_minor:
          to_int(Map.get(band, "per_km_rate_minor") || Map.get(band, :per_km_rate_minor), nil)
      }
    ]
  end

  defp parse_band(_), do: []

  defp decode_json(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> []
    end
  end

  defp to_int(nil, fallback), do: fallback
  defp to_int(value, _fallback) when is_integer(value), do: value
  defp to_int(value, _fallback) when is_float(value), do: trunc(value)

  defp to_int(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> fallback
    end
  end

  defp to_int(_, fallback), do: fallback

  defp to_float(nil), do: nil
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp to_float(_), do: nil

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_), do: nil
end
