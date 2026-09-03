defmodule MithrilWeb.ParityBookingControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  @endpoint MithrilWeb.Endpoint
  @parity_token "test-parity-token"

  setup do
    :ok = Sandbox.checkout(Repo)
    previous = Application.get_env(:mithril, :parity_token)
    Application.put_env(:mithril, :parity_token, @parity_token)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      service_id uuid NOT NULL,
      scheduled_date date NOT NULL,
      scheduled_time time NOT NULL,
      duration_hours integer,
      address text NOT NULL,
      special_instructions text,
      status text,
      total_price integer NOT NULL,
      platform_fee integer,
      tax_amount integer,
      payment_status text,
      payment_method text,
      created_at timestamptz,
      updated_at timestamptz
    )
    """)

    Repo.query!("TRUNCATE TABLE public.bookings")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mithril, :parity_token)
      else
        Application.put_env(:mithril, :parity_token, previous)
      end
    end)

    :ok
  end

  test "parity route denies requests without the server-side token" do
    booking_id = Ecto.UUID.generate()

    conn = get(build_conn(), "/internal/parity/bookings/#{booking_id}")

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  test "parity route returns a legacy booking when authorized" do
    booking_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    service_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings
        (id, customer_id, service_id, scheduled_date, scheduled_time, duration_hours,
         address, status, total_price, platform_fee, tax_amount, payment_status,
         created_at, updated_at)
      VALUES
        ($1, $2, $3, DATE '2026-09-10', TIME '09:30:00', 2,
         'Accra, Ghana', 'pending', 30000, 4500, 0, 'pending', NOW(), NOW())
      """,
      Enum.map([booking_id, customer_id, service_id], &Ecto.UUID.dump!/1)
    )

    conn =
      build_conn()
      |> put_req_header("x-mithril-parity-token", @parity_token)
      |> get("/internal/parity/bookings/#{booking_id}")

    response = json_response(conn, 200)
    assert response["booking"]["id"] == booking_id
    assert response["booking"]["customer_id"] == customer_id
    assert response["booking"]["status"] == "pending"
    assert response["booking"]["total_price"] == 30_000
  end
end
