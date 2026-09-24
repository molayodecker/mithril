defmodule Mithril.CalendarFeedSecurity do
  @moduledoc false

  @max_feed_url_length 2048
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @blocked_hostnames MapSet.new([
                       "localhost",
                       "127.0.0.1",
                       "0.0.0.0",
                       "::1",
                       "metadata.google.internal"
                     ])

  @spec assert_safe_feed_url(String.t(), String.t()) :: :ok | {:error, String.t()}
  def assert_safe_feed_url(raw_url, provider \\ "airbnb") do
    with :ok <- assert_provider(provider),
         {:ok, url} <- parse_https_url(raw_url),
         :ok <- assert_airbnb_host(url),
         :ok <- assert_not_blocked_host(url.host) do
      if String.ends_with?(String.downcase(url.path), ".ics") do
        :ok
      else
        {:error, "Feed URL must point to an .ics calendar export"}
      end
    end
  end

  @spec parse_property_id(term()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_property_id(value) do
    property_id = value |> to_string() |> String.trim()

    if Regex.match?(@uuid_regex, property_id) do
      {:ok, property_id}
    else
      {:error, "property_id must be a UUID"}
    end
  end

  @spec parse_provider(term()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_provider(value) do
    provider =
      case value do
        value when is_binary(value) -> String.trim(value)
        _ -> "airbnb"
      end

    if provider == "airbnb", do: {:ok, provider}, else: {:error, "Unsupported calendar provider"}
  end

  @spec parse_feed_time(term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_feed_time(value, fallback) when is_binary(fallback) do
    raw =
      case value do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    trimmed = if raw == "", do: fallback, else: raw

    cond do
      not Regex.match?(~r/^\d{1,2}:\d{2}(:\d{2})?$/, trimmed) ->
        {:error, "Time must use HH:MM or HH:MM:SS format"}

      true ->
        normalized = if String.length(trimmed) == 5, do: "#{trimmed}:00", else: trimmed

        case Regex.run(~r/^(\d{1,2}):(\d{2}):(\d{2})$/, normalized) do
          [_, hour, minute, second] ->
            hour = String.to_integer(hour)
            minute = String.to_integer(minute)
            second = String.to_integer(second)

            if hour > 23 or minute > 59 or second > 59 do
              {:error, "Time must use HH:MM or HH:MM:SS format"}
            else
              {:ok, normalized}
            end

          _ ->
            {:error, "Time must use HH:MM or HH:MM:SS format"}
        end
    end
  end

  @spec parse_minimum_turnover_minutes(term()) :: {:ok, integer()} | {:error, String.t()}
  def parse_minimum_turnover_minutes(value) do
    minutes =
      case value do
        value when is_integer(value) -> value
        value when is_float(value) -> round(value)
        _ -> 180
      end

    if minutes >= 180 and minutes <= 480 do
      {:ok, minutes}
    else
      {:error, "minimum_turnover_minutes must be between 180 and 480"}
    end
  end

  @spec validate_feed_timing(map()) :: :ok | {:error, String.t()}
  def validate_feed_timing(%{timezone: timezone, default_checkin_time: checkin, default_checkout_time: checkout}) do
    with :ok <- validate_timezone(timezone),
         {:ok, _} <- parse_feed_time(checkin, "15:00:00"),
         {:ok, _} <- parse_feed_time(checkout, "11:00:00") do
      :ok
    end
  end

  defp assert_provider("airbnb"), do: :ok
  defp assert_provider(_), do: {:error, "Only Airbnb calendar feeds are supported"}

  defp parse_https_url(raw) do
    trimmed = raw |> to_string() |> String.trim()

    cond do
      trimmed == "" or String.length(trimmed) > @max_feed_url_length ->
        {:error, "Feed URL is invalid or too long"}

      true ->
        case URI.parse(trimmed) do
          %URI{scheme: "https", host: host, port: port, userinfo: nil} = uri when is_binary(host) ->
            if port in [nil, 443] do
              {:ok, uri}
            else
              {:error, "Feed URL must use port 443"}
            end

          %URI{userinfo: userinfo} when not is_nil(userinfo) ->
            {:error, "Feed URL must not contain credentials"}

          %URI{} ->
            {:error, "Feed URL must use HTTPS"}
        end
    end
  end

  defp assert_airbnb_host(%URI{host: host}) do
    normalized = host |> String.downcase() |> String.trim_trailing(".")

    if normalized == "airbnb.com" or String.ends_with?(normalized, ".airbnb.com") do
      :ok
    else
      {:error, "Feed URL host is not an allowed Airbnb domain"}
    end
  end

  defp assert_not_blocked_host(host) do
    normalized = host |> String.downcase() |> String.trim_trailing(".")

    cond do
      MapSet.member?(@blocked_hostnames, normalized) ->
        {:error, "Feed URL host is not allowed"}

      String.ends_with?(normalized, ".local") ->
        {:error, "Feed URL host is not allowed"}

      private_ipv4?(normalized) ->
        {:error, "Feed URL host is not allowed"}

      String.starts_with?(normalized, "fe80:") or String.starts_with?(normalized, "fc") or
          String.starts_with?(normalized, "fd") ->
        {:error, "Feed URL host is not allowed"}

      true ->
        :ok
    end
  end

  defp private_ipv4?(host) do
    case String.split(host, ".") do
      [a, b | _] ->
        a = String.to_integer(a)
        b = String.to_integer(b)

        a == 10 or a == 127 or (a == 169 and b == 254) or (a == 172 and b in 16..31) or
          (a == 192 and b == 168) or a == 0

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp validate_timezone(timezone) when is_binary(timezone) do
    case DateTime.now(timezone) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "Invalid timezone: #{timezone}"}
    end
  end
end