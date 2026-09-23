defmodule MithrilWeb.MobileGatewayControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mithril.Auth.Token

  @endpoint MithrilWeb.Endpoint

  test "POST /mobile/rpc/:name requires a bearer token" do
    conn = post(build_conn(), "/mobile/rpc/get_my_wallet_balance", %{})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
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
