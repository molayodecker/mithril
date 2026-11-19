defmodule MithrilWeb.Plugs.DirectOpsAuthorizationTest do
  use ExUnit.Case, async: true

  alias MithrilWeb.Plugs.DirectOpsAuthorization

  test "a reviewer can send WhatsApp without the WhatsApp desk" do
    assert DirectOpsAuthorization.reviewer_whatsapp_send?(
             ["reviewer", "contracts"],
             ["whatsapp", "send"],
             "POST"
           )

    assert DirectOpsAuthorization.reviewer_whatsapp_send?(
             ["reviewer", "bookings"],
             ["contracts", "contract-id", "worker-rating"],
             "POST"
           )
  end

  test "a reviewer desk grant does not open other routes" do
    refute DirectOpsAuthorization.reviewer_whatsapp_send?(
             ["reviewer", "contracts"],
             ["contracts", "contract-id", "payday"],
             "POST"
           )

    refute DirectOpsAuthorization.reviewer_whatsapp_send?(
             ["bookings"],
             ["whatsapp", "send"],
             "POST"
           )
  end

  test "concierge can search customers and create a booking" do
    assert DirectOpsAuthorization.permissions_for(["customers"], "GET") == ["users", "dispatch"]
    assert DirectOpsAuthorization.permissions_for(["bookings"], "POST") == ["bookings", "dispatch"]
  end

  test "booking desk reads and mutations stay on the bookings permission" do
    assert DirectOpsAuthorization.permissions_for(["bookings"], "GET") == ["bookings"]

    assert DirectOpsAuthorization.permissions_for(["bookings", "booking-id", "cancel"], "POST") == [
             "bookings"
           ]

    assert DirectOpsAuthorization.permissions_for(["bookings", "booking-id", "invoice"], "GET") == [
             "billing"
           ]
  end

  test "placement and roster lists stay on their own desks" do
    assert DirectOpsAuthorization.permissions_for(["candidates"], "GET") == ["placements"]
    assert DirectOpsAuthorization.permissions_for(["cleaners"], "GET") == ["cleaners_roster"]
  end
end
