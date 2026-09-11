defmodule Mithril.DirectBookingsListTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectBookings
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_booking_tables!()
    :ok
  end

  test "lists only the signed-in customer's bookings, newest first" do
    customer_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    older = insert_booking!(customer_id, ~D[2026-09-10], ~T[09:00:00], "scheduled")
    newer = insert_booking!(customer_id, ~D[2026-09-20], ~T[14:00:00], "pending")
    _other = insert_booking!(other_id, ~D[2026-09-22], ~T[08:00:00], "scheduled")

    assert {:ok, bookings} = DirectBookings.list_bookings(customer_id)
    assert Enum.map(bookings, & &1["id"]) == [newer, older]
    assert hd(bookings)["serviceName"] == "Regular Cleaning"
    assert hd(bookings)["amountMinor"] == 19_350
    assert hd(bookings)["currency"] == "GHS"
  end

  test "returns an empty list when the customer has no bookings" do
    assert {:ok, []} = DirectBookings.list_bookings(Ecto.UUID.generate())
  end

  defp insert_booking!(customer_id, scheduled_date, scheduled_time, status) do
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.users (id, email, status)
      VALUES ($1, 'customer@example.com', 'active')
      ON CONFLICT (id) DO NOTHING
      """,
      [Ecto.UUID.dump!(customer_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, service_id, status, payment_status,
        scheduled_date, scheduled_time, duration_hours, address,
        final_amount_minor, total_price, currency
      ) VALUES (
        $1, $2, 1, $3, 'pending', $4, $5, 3, 'Labone, Accra',
        19350, 19350, 'GHS'
      )
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(customer_id),
        status,
        scheduled_date,
        scheduled_time
      ]
    )

    booking_id
  end

  defp create_booking_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate booking fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.service_types CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.profiles CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      status text NOT NULL DEFAULT 'active'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      lastname text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_types (
      id integer PRIMARY KEY,
      name text NOT NULL
    )
    """)

    Repo.query!("INSERT INTO public.service_types (id, name) VALUES (1, 'Regular Cleaning')")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      service_id integer NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      payment_status text NOT NULL DEFAULT 'pending',
      scheduled_date date,
      scheduled_time time,
      duration_hours numeric,
      address text,
      final_amount_minor bigint,
      total_price numeric,
      currency text NOT NULL DEFAULT 'GHS',
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)
  end
end
