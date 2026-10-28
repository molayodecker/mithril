defmodule MithrilWeb.MobileCallRoutesTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mithril.Auth.Token
  alias Mithril.MobileGateway
  alias Mithril.MobileRpc

  @endpoint MithrilWeb.Endpoint

  test "each allowlisted RPC and function has a static path" do
    paths = MithrilWeb.Router.__routes__()

    for name <- MobileRpc.names() do
      assert_route(paths, :post, "/mobile/calls/#{kebab(name)}", {:user_rpc, name})
    end

    for name <- MobileGateway.guest_rpc_names() do
      assert_route(paths, :post, "/mobile/guest/calls/#{kebab(name)}", {:guest_rpc, name})
    end

    for name <- MobileGateway.function_names() do
      assert_route(paths, :post, "/mobile/actions/#{name}", {:user_action, name})
    end

    for name <- MobileGateway.guest_function_names() do
      assert_route(paths, :post, "/mobile/guest/actions/#{name}", {:guest_action, name})
    end

    refute Enum.any?(paths, &(&1.path == "/mobile/calls/pg-read-file"))
    refute Enum.any?(paths, &(&1.path == "/mobile/guest/calls/get-my-wallet-balance"))
  end

  test "documented mobile calls publish an OpenAPI operation" do
    spec = MithrilWeb.ApiSpec.spec()

    service_area = spec.paths["/mobile/calls/is-location-in-active-service-area"].post
    guest_service_area = spec.paths["/mobile/guest/calls/is-location-in-active-service-area"].post

    assert service_area.operationId == "mobile.checkServiceArea"
    assert guest_service_area.operationId == "mobile.checkServiceAreaGuest"
    assert spec.components.schemas["MobileServiceAreaRequest"]
    assert spec.components.schemas["MobileWalletBalanceResponse"]

    assert spec.paths["/mobile/calls/get-my-wallet-balance"].post.operationId ==
             "mobile.getMyWalletBalance"

    assert spec.paths["/mobile/guest/calls/get-available-timeslots"].post.operationId ==
             "mobile.getAvailableTimeslotsGuest"

    assert spec.paths["/mobile/guest/actions/timezone"].post.operationId ==
             "mobile.getTimezoneGuest"

    assert spec.components.schemas["MobileAvailableTimeslotsRequest"]
    assert spec.components.schemas["MobileTimezoneRequest"]
  end

  test "POST /mobile/calls/get-my-wallet-balance requires a bearer token" do
    conn = post(build_conn(), "/mobile/calls/get-my-wallet-balance", %{})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "POST /mobile/actions/claim-job requires a bearer token" do
    conn = post(build_conn(), "/mobile/actions/claim-job", %{})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "a signed-in call for an unknown database function does not run SQL" do
    user_id = Ecto.UUID.generate()
    {:ok, access_token, _claims} = Token.issue(user_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post("/mobile/calls/not-a-function", %{})

    assert response(conn, 404)
  end

  defp assert_route(routes, verb, path, opts) do
    route = Enum.find(routes, &(&1.verb == verb && &1.path == path))
    assert route, "missing #{verb} #{path}"
    assert route.plug == MithrilWeb.Plugs.MobileCall
    assert route.plug_opts == opts
  end

  defp kebab(name), do: String.replace(name, "_", "-")
end
