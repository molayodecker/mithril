defmodule Mithril.GuestMobileRateLimit do
  @moduledoc false

  alias Mithril.RateLimiter

  @default_guest_prep_limit 240
  @default_guest_prep_window_ms 60_000
  @default_timezone_limit 60
  @default_timezone_window_ms 60_000

  @spec check_guest_prep(String.t() | nil) :: :ok | {:error, :rate_limited}
  def check_guest_prep(client_ip) do
    RateLimiter.check(
      {:guest_mobile_prep, normalize_ip(client_ip)},
      guest_prep_limit(),
      guest_prep_window_ms()
    )
  end

  @spec check_guest_timezone(String.t() | nil) :: :ok | {:error, :rate_limited}
  def check_guest_timezone(client_ip) do
    with :ok <- check_guest_prep(client_ip),
         :ok <-
           RateLimiter.check(
             {:guest_mobile_timezone, normalize_ip(client_ip)},
             timezone_limit(),
             timezone_window_ms()
           ) do
      :ok
    end
  end

  defp normalize_ip(ip) when is_binary(ip) and ip != "", do: ip
  defp normalize_ip(_), do: "unknown"

  defp guest_prep_limit do
    env_limit(:guest_mobile_prep_limit, @default_guest_prep_limit)
  end

  defp guest_prep_window_ms do
    env_window_ms(:guest_mobile_prep_window_ms, @default_guest_prep_window_ms)
  end

  defp timezone_limit do
    env_limit(:guest_mobile_timezone_limit, @default_timezone_limit)
  end

  defp timezone_window_ms do
    env_window_ms(:guest_mobile_timezone_window_ms, @default_timezone_window_ms)
  end

  defp env_limit(key, default) do
    case Application.get_env(:mithril, key) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> default
    end
  end

  defp env_window_ms(key, default) do
    case Application.get_env(:mithril, key) do
      window_ms when is_integer(window_ms) and window_ms > 0 -> window_ms
      _ -> default
    end
  end
end
