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

  test "POST /mobile/functions/send-notification cannot spoof another recipient" do
    conn =
      authenticated_post("/mobile/functions/send-notification", %{
        "userId" => Ecto.UUID.generate()
      })

    assert json_response(conn, 403)["error"] == "forbidden"
  end

  test "POST /mobile/functions/fetch-otp-delivery-token is not available on the JWT gateway" do
    conn =
      authenticated_post("/mobile/functions/fetch-otp-delivery-token", %{
        "phone" => "+233201234567"
      })

    assert json_response(conn, 403)["error"] == "forbidden"
  end

  test "POST /mobile/functions/resend-otp-via-channel is not available on the JWT gateway" do
    conn =
      authenticated_post("/mobile/functions/resend-otp-via-channel", %{"phone" => "+233201234567"})

    assert json_response(conn, 403)["error"] == "forbidden"
  end

  test "POST /mobile/functions/uber-trip-estimate is retired" do
    conn =
      authenticated_post("/mobile/functions/uber-trip-estimate", %{
        "cleaner_id" => Ecto.UUID.generate(),
        "customer_latitude" => 5.6,
        "customer_longitude" => -0.2
      })

    body = json_response(conn, 410)
    assert body["code"] == "uber_estimate_removed"
  end

  defp authenticated_post(path, body) do
    user_id = Ecto.UUID.generate()
    {:ok, access_token, _claims} = Token.issue(user_id, "jwt@example.com")

    build_conn()
    |> put_req_header("authorization", "Bearer #{access_token}")
    |> post(path, body)
  end
end
