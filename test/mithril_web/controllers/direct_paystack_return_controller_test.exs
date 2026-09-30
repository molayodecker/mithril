defmodule MithrilWeb.DirectPaystackReturnControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  @booking_id "550e8400-e29b-4164-a716-446655440000"

  test "GET /bookings/:id returns HTML that deep-links into the app" do
    conn =
      get(
        build_conn(),
        "/bookings/#{@booking_id}?scheme=instaclean-preview&reference=BK-123"
      )

    assert response(conn, 200) =~ "Returning to Instaclean"
    assert response(conn, 200) =~ "instaclean-preview://booking-status?"
    assert response(conn, 200) =~ "bookingId=#{@booking_id}"
    assert response(conn, 200) =~ "reference=BK-123"
    assert {"cache-control", "no-store"} in conn.resp_headers
  end

  test "GET /bookings/:id tolerates structured scheme input without a 500" do
    conn =
      get(
        build_conn(),
        "/bookings/#{@booking_id}?scheme[value]=instaclean-preview&reference=BK-123"
      )

    body = response(conn, 200)
    assert body =~ "instaclean://booking-status?"
    refute body =~ "instaclean-preview://booking-status?"
  end

  test "GET /bookings/:id rejects javascript scheme injection" do
    conn =
      get(
        build_conn(),
        "/bookings/#{@booking_id}?scheme=javascript&reference=%0Aalert(document.domain)"
      )

    body = response(conn, 200)
    assert body =~ "instaclean://booking-status?"
    refute body =~ "javascript://"
  end

  test "GET /bookings/:id rejects invalid ids" do
    conn = get(build_conn(), "/bookings/not-a-uuid")
    assert response(conn, 400) =~ "Invalid booking ID"
  end
end
