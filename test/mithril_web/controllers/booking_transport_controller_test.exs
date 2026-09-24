defmodule MithrilWeb.BookingTransportControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mithril.Auth.Token

  @endpoint MithrilWeb.Endpoint

  test "GET /bookings/:id/transport-estimate requires a bearer token" do
    conn = get(build_conn(), "/bookings/#{Ecto.UUID.generate()}/transport-estimate")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /bookings/:id/transport-estimate rejects a malformed id" do
    {:ok, access_token, _claims} = Token.issue(Ecto.UUID.generate(), "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/bookings/not-a-uuid/transport-estimate")

    assert json_response(conn, 400)["error"] == "Invalid booking id"
  end

  test "GET /bookings/:id/transport-estimate hides unknown bookings" do
    {:ok, access_token, _claims} = Token.issue(Ecto.UUID.generate(), "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/bookings/#{Ecto.UUID.generate()}/transport-estimate")

    assert json_response(conn, 404)["error"] == "Booking not found"
  end
end
