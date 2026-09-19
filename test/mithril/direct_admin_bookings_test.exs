defmodule Mithril.DirectAdminBookingsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminBookings
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate admin booking fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "payout_methods",
          "wallets",
          "bookings",
          "service_types",
          "profiles",
          "user_roles",
          "users"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text
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
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_types (
      id integer PRIMARY KEY,
      name text NOT NULL,
      active boolean NOT NULL DEFAULT true
    )
    """)

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
      timezone text,
      address text,
      special_instructions text,
      total_price numeric,
      final_amount_minor integer,
      cleaner_earnings_minor integer,
      currency text,
      assignment_phase text,
      assignment_hold_until timestamptz,
      cleaner_accepted_at timestamptz,
      direct_assigned_cleaner_id uuid,
      cleaner_assigned_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.wallets (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid UNIQUE,
      balance_subunit integer,
      currency text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payout_methods (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      bank_name text,
      masked_account text,
      account_name text,
      account_number text NOT NULL,
      is_primary boolean,
      is_default boolean,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("INSERT INTO public.service_types (id, name) VALUES (1, 'Deep Cleaning')")

    :ok
  end

  test "rejects non-staff users" do
    customer_id = insert_user!("customer@example.com", "+233500000001")
    assert {:error, :forbidden} = DirectAdminBookings.list_bookings(customer_id)
  end

  test "lists and shows a booking for ops" do
    admin_id = insert_admin!()
    customer_id = insert_user!("trekandy18@gmail.com", "+233500000002", "Andrew Aryee")
    cleaner_id = insert_user!("evelyn@example.com", "+233500000003", "Evelyn Pekuson")
    booking_id = insert_booking!(customer_id, cleaner_id)

    assert {:ok, [booking]} = DirectAdminBookings.list_bookings(admin_id)
    assert booking["id"] == booking_id
    assert booking["customerName"] == "Andrew Aryee"
    assert booking["cleanerName"] == "Evelyn Pekuson"
    assert booking["amountMinor"] == 28166
    assert booking["cleanerEarningsMinor"] == 22841
    assert booking["canCancel"] == false
    assert booking["canRecordCashPayout"] == true

    assert {:ok, detail} = DirectAdminBookings.get_booking(admin_id, booking_id)
    assert detail["payoutMethod"]["accountNumber"] == "1234567890"
    assert detail["walletBalanceMinor"] == 23671
  end

  test "assigns a cleaner and updates status" do
    admin_id = insert_admin!()
    customer_id = insert_user!("customer@example.com", "+233500000004")
    cleaner_id = insert_user!("cleaner@example.com", "+233500000005", "New Cleaner")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'cleaner')", [
      Ecto.UUID.dump!(cleaner_id)
    ])

    booking_id = insert_booking!(customer_id, nil, "pending")

    assert {:ok, assigned} =
             DirectAdminBookings.assign_cleaner(admin_id, booking_id, %{
               "cleanerId" => cleaner_id
             })

    assert assigned["cleanerId"] == cleaner_id
    assert assigned["status"] == "confirmed"

    assert {:ok, updated} =
             DirectAdminBookings.update_status(admin_id, booking_id, %{"status" => "scheduled"})

    assert updated["status"] == "scheduled"
    assert updated["canReassignCleaner"] == true
  end

  defp insert_admin! do
    admin_id = insert_user!("ops@tryinstaclean.com", "+233500000099", "Ops")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    admin_id
  end

  defp insert_user!(email, phone, name \\ nil) do
    id = Ecto.UUID.generate()
    uid = Ecto.UUID.dump!(id)

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      uid,
      email,
      phone
    ])

    if name do
      Repo.query!("INSERT INTO public.profiles (id, fullname) VALUES ($1, $2)", [uid, name])
    end

    id
  end

  defp insert_booking!(customer_id, cleaner_id, status \\ "completed") do
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, cleaner_id, service_id, status, payment_status,
        scheduled_date, scheduled_time, duration_hours, timezone, address,
        special_instructions, total_price, final_amount_minor, cleaner_earnings_minor,
        currency
      ) VALUES (
        $1, $2, $3, 1, $4, 'paid', '2026-09-13', '08:00', 4, 'Africa/Accra',
        'Shell Signboard, Spintex Rd, Accra, Ghana', NULL, 28166, 28166, 22841, 'GHS'
      )
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(customer_id),
        dump_optional(cleaner_id),
        status
      ]
    )

    if cleaner_id do
      Repo.query!(
        "INSERT INTO public.wallets (user_id, balance_subunit, currency) VALUES ($1, 23671, 'GHS')",
        [Ecto.UUID.dump!(cleaner_id)]
      )

      Repo.query!(
        """
        INSERT INTO public.payout_methods (
          user_id, bank_name, masked_account, account_name, account_number, is_primary
        ) VALUES ($1, 'Fidelity Bank Ghana Limited', '•••• 9…', 'EVELYN PEKUSON', '1234567890', true)
        """,
        [Ecto.UUID.dump!(cleaner_id)]
      )
    end

    booking_id
  end

  defp dump_optional(nil), do: nil
  defp dump_optional(id), do: Ecto.UUID.dump!(id)
end
