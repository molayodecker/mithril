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
end
