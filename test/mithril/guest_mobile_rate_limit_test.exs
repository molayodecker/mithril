defmodule Mithril.GuestMobileRateLimitTest do
  use ExUnit.Case, async: false

  alias Mithril.GuestMobileRateLimit

  defp restore_env(key, prev) do
    if prev == nil do
      Application.delete_env(:mithril, key)
    else
      Application.put_env(:mithril, key, prev)
    end
  end

  setup do
    prev_prep = Application.get_env(:mithril, :guest_mobile_prep_limit)
    prev_tz = Application.get_env(:mithril, :guest_mobile_timezone_limit)

    Application.put_env(:mithril, :guest_mobile_prep_limit, 3)
    Application.put_env(:mithril, :guest_mobile_timezone_limit, 2)

    on_exit(fn ->
      restore_env(:guest_mobile_prep_limit, prev_prep)
      restore_env(:guest_mobile_timezone_limit, prev_tz)
    end)

    ip = "198.51.100.#{rem(System.unique_integer([:positive]), 200) + 1}"
    {:ok, ip: ip}
  end

  test "guest prep allows requests under the per-ip limit", %{ip: ip} do
    assert :ok = GuestMobileRateLimit.check_guest_prep(ip)
    assert :ok = GuestMobileRateLimit.check_guest_prep(ip)
    assert :ok = GuestMobileRateLimit.check_guest_prep(ip)
    assert {:error, :rate_limited} = GuestMobileRateLimit.check_guest_prep(ip)
  end

  test "guest timezone uses a stricter limit than prep alone", %{ip: ip} do
    assert :ok = GuestMobileRateLimit.check_guest_timezone(ip)
    assert :ok = GuestMobileRateLimit.check_guest_timezone(ip)
    assert {:error, :rate_limited} = GuestMobileRateLimit.check_guest_timezone(ip)
  end
end
