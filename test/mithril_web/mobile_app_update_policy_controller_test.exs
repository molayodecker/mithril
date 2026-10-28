defmodule MithrilWeb.MobileAppUpdatePolicyControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  test "the guest policy route is public and returns one nullable policy" do
    spec = MithrilWeb.ApiSpec.spec()
    operation = spec.paths["/mobile/guest/app-update-policy"].get

    assert operation.operationId == "mobile.getAppUpdatePolicy"
    assert operation.security == []
    assert spec.components.schemas["MobileAppUpdatePolicyResponse"]
    assert spec.components.schemas["MobileAppUpdatePolicy"]
  end

  test "an unknown app is rejected before a database read" do
    conn = get(build_conn(), "/mobile/guest/app-update-policy?app=admin&channel=production")

    assert json_response(conn, 400) == %{"error" => "bad_request"}
  end
end
