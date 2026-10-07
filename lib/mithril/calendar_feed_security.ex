defmodule Mithril.CalendarFeedSecurity do
  @moduledoc false

  @max_feed_url_length 2048
  @max_response_bytes 5 * 1024 * 1024
  @fetch_timeout_ms 20_000
  @max_redirects 3
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @blocked_hostnames MapSet.new([
                       "localhost",
                       "127.0.0.1",
                       "0.0.0.0",
                       "::1",
                       "metadata.google.internal"
                     ])

  @spec fetch_feed_text(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_feed_text(raw_url, provider \\ "airbnb") do
    with :ok <- assert_safe_feed_url(raw_url, provider),
         {:ok, url} <- parse_https_url(raw_url) do
      fetch_with_redirects(url, provider, 0)
    else
      {:error, message} -> {:error, message}
    end
  end

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

  @spec validate_feed_timing(map()) ::
          :ok | {:error, String.t()} | {:error, {:timezone_database, term()}}
  def validate_feed_timing(%{
        timezone: timezone,
        default_checkin_time: checkin,
        default_checkout_time: checkout
      }) do
    with {:ok, _normalized_timezone} <- normalize_timezone(timezone),
         {:ok, _} <- parse_feed_time(checkin, "15:00:00"),
         {:ok, _} <- parse_feed_time(checkout, "11:00:00") do
      :ok
    end
  end

  @spec normalize_timezone(term()) ::
          {:ok, String.t()} | {:error, String.t()} | {:error, {:timezone_database, term()}}
  def normalize_timezone(timezone) when is_binary(timezone) do
    trimmed = String.trim(timezone)

    if trimmed == "" do
      {:error, "Invalid timezone: #{timezone}"}
    else
      case Mithril.Repo.query(
             "SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)",
             [trimmed]
           ) do
        {:ok, %{rows: [[true]]}} -> {:ok, trimmed}
        {:ok, _} -> {:error, "Invalid timezone: #{trimmed}"}
        {:error, reason} -> {:error, {:timezone_database, reason}}
      end
    end
  end

  def normalize_timezone(timezone), do: {:error, "Invalid timezone: #{inspect(timezone)}"}

  defp fetch_with_redirects(_url, _provider, redirect_count)
       when redirect_count > @max_redirects do
    {:error, "Feed exceeded maximum redirects"}
  end

  defp fetch_with_redirects(%URI{} = url, provider, redirect_count) do
    case calendar_http_get(URI.to_string(url)) do
      {:ok, %{status: status} = response} when status in 300..399 ->
        location = response.headers["location"] || response.headers["Location"]

        with location when is_binary(location) <- location,
             {:ok, next_url} <- parse_https_url(URI.merge(url, location) |> URI.to_string()),
             :ok <- assert_airbnb_host(next_url),
             :ok <- assert_not_blocked_host(next_url.host) do
          fetch_with_redirects(next_url, provider, redirect_count + 1)
        else
          {:error, message} when is_binary(message) -> {:error, message}
          _ -> {:error, "Feed redirect missing location"}
        end

      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        if byte_size(body) > @max_response_bytes do
          {:error, "Calendar response exceeds maximum size"}
        else
          if String.contains?(body, "BEGIN:VCALENDAR") do
            {:ok, body}
          else
            {:error, "Feed response is not a calendar document"}
          end
        end

      {:ok, %{status: status}} ->
        {:error, "Feed HTTP #{status}"}

      {:error, _} ->
        {:error, "Feed request failed"}
    end
  end

  defp calendar_http_get(url) do
    case Application.get_env(:mithril, :calendar_feed_http_get) do
      fun when is_function(fun, 1) ->
        fun.(url)

      _ ->
        Req.get(url,
          headers: [{"accept", "text/calendar,*/*"}],
          receive_timeout: @fetch_timeout_ms,
          redirect: false
        )
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
          %URI{scheme: "https", host: host, port: port, userinfo: nil} = uri
          when is_binary(host) ->
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

end
