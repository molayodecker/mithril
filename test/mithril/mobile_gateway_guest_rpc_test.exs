defmodule Mithril.MobileGatewayGuestRpcTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileGateway

  test "rejects a name that is not a string" do
    assert MobileGateway.call_guest_rpc(nil, %{}) == {:error, :unknown_function}
  end

  test "rejects an unknown function even when args are omitted" do
    assert MobileGateway.call_guest_rpc("get_my_wallet_balance", nil) ==
             {:error, :unknown_function}
  end

  test "rejects args that are not a map" do
    assert MobileGateway.call_guest_rpc("get_available_timeslots", ["bad"]) ==
             {:error, :forbidden}
  end

  test "rejects extra-task hour updates passed with an atom key" do
    assert MobileGateway.call_guest_rpc("manage_extra_tasks", %{action: "update_hours"}) ==
             {:error, :forbidden}
  end

  test "rejects a cleaning scan id passed with an atom key" do
    assert MobileGateway.call_guest_rpc("compute_booking_pricing", %{
             p_cleaning_scan_id: "scan-1"
           }) == {:error, :forbidden}
  end

  test "public booking pricing hides compensation and margin fields" do
    payload = [
      %{
        "final_amount_minor" => 12_000,
        "cleaner_earnings_minor" => 7_000,
        "platform_margin_minor" => 5_000,
        "workerPayoutMinor" => 7_000,
        "details" => %{"profit_amount" => 5_000, "customer_total" => 12_000}
      }
    ]

    assert MobileGateway.sanitize_guest_rpc_result({:ok, payload}, "compute_booking_pricing") ==
             {:ok,
              [%{"final_amount_minor" => 12_000, "details" => %{"customer_total" => 12_000}}]}

    assert MobileGateway.sanitize_guest_rpc_result({:ok, payload}, "get_available_timeslots") ==
             {:ok, payload}
  end

  test "rejects guest functions outside the allowlist" do
    assert MobileGateway.call_guest_function("connect-property-calendar", %{}) ==
             {:error, :unknown_function}
  end
end
