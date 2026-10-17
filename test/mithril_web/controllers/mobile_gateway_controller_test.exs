defmodule MithrilWeb.MobileGatewayControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mithril.Auth.Token

  @endpoint MithrilWeb.Endpoint

  test "POST /mobile/rpc/:name requires a bearer token" do
    conn = post(build_conn(), "/mobile/rpc/get_my_wallet_balance", %{})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "POST /mobile/guest/rpc rejects account functions" do
    conn = post(build_conn(), "/mobile/guest/rpc/get_my_wallet_balance", %{"args" => %{}})

    assert json_response(conn, 404)["error"] == "unknown_function"
  end

  test "POST /mobile/guest/functions rejects account functions" do
    conn = post(build_conn(), "/mobile/guest/functions/connect-property-calendar", %{})

    assert json_response(conn, 404)["error"] == "unknown_function"
  end

  test "POST /mobile/guest/rpc returns 429 when the guest prep rate limit is exceeded" do
    prev = Application.get_env(:mithril, :guest_mobile_prep_limit)
    Application.put_env(:mithril, :guest_mobile_prep_limit, 2)

    on_exit(fn ->
      if prev == nil do
        Application.delete_env(:mithril, :guest_mobile_prep_limit)
      else
        Application.put_env(:mithril, :guest_mobile_prep_limit, prev)
      end
    end)

    ip = "203.0.113.#{rem(System.unique_integer([:positive]), 200) + 1}"

    base_conn =
      build_conn()
      |> put_req_header("fly-client-ip", ip)

    guest_rpc = fn ->
      post(base_conn, "/mobile/guest/rpc/get_my_wallet_balance", %{"args" => %{}})
    end

    refute guest_rpc.().status == 429
    refute guest_rpc.().status == 429
    assert json_response(guest_rpc.(), 429) == %{"error" => "guest_rate_limited"}
  end

  test "POST /mobile/guest/rpc rejects extra-task hour updates" do
    conn =
      post(build_conn(), "/mobile/guest/rpc/manage_extra_tasks", %{
        "args" => %{"action" => "update_hours", "task_id" => "windows", "new_hours" => 2}
      })

    assert json_response(conn, 403)["error"] == "forbidden"
  end

  test "POST /mobile/rpc/:name rejects functions outside the allowlist" do
    user_id = Ecto.UUID.generate()
    {:ok, access_token, _claims} = Token.issue(user_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post("/mobile/rpc/pg_read_file", %{"args" => %{}})

    assert json_response(conn, 404)["error"] == "unknown_function"
  end

  test "POST /mobile/query rejects unknown tables before touching the database" do
    user_id = Ecto.UUID.generate()
    {:ok, access_token, _claims} = Token.issue(user_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post("/mobile/query", %{"table" => "pg_shadow", "action" => "select"})

    assert json_response(conn, 404)["error"] == "unknown_table"
  end

  test "POST /mobile/query rejects booking lifecycle mutations" do
    user_id = Ecto.UUID.generate()
    {:ok, access_token, _claims} = Token.issue(user_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post("/mobile/query", %{
        "table" => "bookings",
        "action" => "update",
        "patch" => %{"payment_status" => "paid"}
      })

    assert json_response(conn, 403)["error"] == "forbidden"
  end
end
