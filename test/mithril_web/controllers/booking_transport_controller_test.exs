defmodule MithrilWeb.BookingTransportControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Auth.Token
  alias Mithril.Repo

  @endpoint MithrilWeb.Endpoint

  setup do
    :ok = Sandbox.checkout(Repo)
    create_bookings_table!()
    :ok
  end

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

  test "GET /bookings/:id/transport-estimate hides bookings the caller does not own" do
    caller_id = Ecto.UUID.generate()
    booking_id = insert_booking!(Ecto.UUID.generate(), Ecto.UUID.generate())
    {:ok, access_token, _claims} = Token.issue(caller_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/bookings/#{booking_id}/transport-estimate")

    assert json_response(conn, 404)["error"] == "Booking not found"
  end

  test "GET /bookings/:id/transport-estimate reads jsonb booking coordinates" do
    customer_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, cleaner_id)
    {:ok, access_token, _claims} = Token.issue(customer_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/bookings/#{booking_id}/transport-estimate")

    refute conn.status == 500
    assert json_response(conn, 422)["code"] in ["cleaner_location_missing", "destination_missing"]
  end

  defp insert_booking!(customer_id, cleaner_id) do
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings
        (id, customer_id, cleaner_id, status, address, location_coordinates)
      VALUES ($1, $2, $3, 'confirmed', 'East Legon, Accra',
              '{"latitude": 5.65, "longitude": -0.18}'::jsonb)
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), Ecto.UUID.dump!(cleaner_id)]
    )

    booking_id
  end

  defp create_bookings_table! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate bookings; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.bookings")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      status text,
      address text,
      location_coordinates jsonb
    )
    """)
  end
end
