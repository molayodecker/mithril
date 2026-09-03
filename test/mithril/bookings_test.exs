defmodule Mithril.BookingsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Bookings
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_legacy_booking_table!()
    Repo.query!("TRUNCATE TABLE public.bookings")
    :ok
  end

  test "reads a booking from the legacy public.bookings table without owning its DDL" do
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
        ($1, $2, $3, DATE '2026-09-10', TIME '09:30:00', 3,
         'East Legon, Accra', 'pending', 45000, 6750, 0, 'pending', NOW(), NOW())
      """,
      [booking_id, customer_id, service_id]
    )

    assert {:ok, booking} = Bookings.get_booking(booking_id)
    assert booking.id == booking_id
    assert booking.customer_id == customer_id
    assert booking.service_id == service_id
    assert booking.duration_hours == 3
    assert booking.address == "East Legon, Accra"
    assert booking.status == "pending"
    assert booking.total_price == 45_000
  end

  test "rejects malformed booking ids before querying" do
    assert {:error, :invalid_id} = Bookings.get_booking("not-a-uuid")
  end

  defp create_legacy_booking_table! do
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
  end
end
