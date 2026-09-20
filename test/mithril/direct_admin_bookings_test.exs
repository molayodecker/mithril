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
          "cleaner_availability_exceptions",
          "cleaner_data",
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
      specialty_slug text NOT NULL,
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
      timezone_name text,
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
      booking_period tstzrange,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY,
      verified boolean NOT NULL DEFAULT false,
      status text NOT NULL DEFAULT 'pending',
      hourly_rate numeric,
      specialties text[]
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_availability_exceptions (
      cleaner_id uuid NOT NULL,
      exception_date date NOT NULL
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.cleaner_has_booking_conflict(
      p_cleaner_id uuid,
      p_booking_start timestamptz,
      p_booking_end timestamptz,
      p_exclude_booking_id uuid DEFAULT NULL
    )
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$
      SELECT EXISTS (
        SELECT 1
        FROM public.bookings b
        WHERE b.cleaner_id = p_cleaner_id
          AND b.status NOT IN ('cancelled', 'completed')
          AND (p_exclude_booking_id IS NULL OR b.id <> p_exclude_booking_id)
          AND b.booking_period IS NOT NULL
          AND b.booking_period && tstzrange(p_booking_start, p_booking_end, '[)')
      )
    $$;
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

    Repo.query!(
      "INSERT INTO public.service_types (id, name, specialty_slug) VALUES (1, 'Deep Cleaning', 'cleaning')"
    )

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

    activate_cleaner!(cleaner_id)

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

  test "persists a derived booking period when assigning a legacy booking" do
    admin_id = insert_admin!()
    customer_id = insert_user!("legacy@example.com", "+233500000040")
    other_customer_id = insert_user!("legacy2@example.com", "+233500000041")
    cleaner_id = insert_user!("legacy-cleaner@example.com", "+233500000042", "Legacy Cleaner")
    activate_cleaner!(cleaner_id)

    booking_id = insert_booking!(customer_id, nil, "pending")

    Repo.query!(
      """
      UPDATE public.bookings
      SET booking_period = NULL,
          timezone = 'America/New_York',
          timezone_name = 'Africa/Accra'
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(booking_id)]
    )

    assert {:ok, _assigned} =
             DirectAdminBookings.assign_cleaner(admin_id, booking_id, %{
               "cleanerId" => cleaner_id
             })

    assert [[%DateTime{} = starts_at, %DateTime{} = ends_at]] =
             Repo.query!(
               "SELECT lower(booking_period), upper(booking_period) FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert DateTime.compare(starts_at, ~U[2030-09-13 08:00:00Z]) == :eq
    assert DateTime.compare(ends_at, ~U[2030-09-13 12:00:00Z]) == :eq

    overlapping_booking_id = insert_booking!(other_customer_id, nil, "pending")

    assert {:error, :cleaner_unavailable} =
             DirectAdminBookings.assign_cleaner(admin_id, overlapping_booking_id, %{
               "cleanerId" => cleaner_id
             })
  end

  test "rejects cleaner assignment when the cleaner is unavailable on the booking date" do
    admin_id = insert_admin!()
    customer_id = insert_user!("customer2@example.com", "+233500000014")
    cleaner_id = insert_user!("blocked@example.com", "+233500000015", "Blocked Cleaner")
    activate_cleaner!(cleaner_id)
    booking_id = insert_booking!(customer_id, nil, "pending")

    Repo.query!(
      "INSERT INTO public.cleaner_availability_exceptions (cleaner_id, exception_date) VALUES ($1, '2030-09-13')",
      [Ecto.UUID.dump!(cleaner_id)]
    )

    assert {:error, :cleaner_unavailable} =
             DirectAdminBookings.assign_cleaner(admin_id, booking_id, %{"cleanerId" => cleaner_id})
  end

  test "rejects cleaner assignment when another booking conflicts" do
    admin_id = insert_admin!()
    customer_id = insert_user!("customer3@example.com", "+233500000024")
    other_customer_id = insert_user!("customer4@example.com", "+233500000025")
    cleaner_id = insert_user!("busy@example.com", "+233500000026", "Busy Cleaner")
    activate_cleaner!(cleaner_id)

    _conflicting_booking = insert_booking!(other_customer_id, cleaner_id, "scheduled")
    booking_id = insert_booking!(customer_id, nil, "pending")

    assert {:error, :cleaner_unavailable} =
             DirectAdminBookings.assign_cleaner(admin_id, booking_id, %{"cleanerId" => cleaner_id})
  end

  test "retrying the same cleaner assignment preserves accepted dispatch state" do
    admin_id = insert_admin!()
    customer_id = insert_user!("customer-retry@example.com", "+233500000027")
    cleaner_id = insert_user!("retry@example.com", "+233500000028", "Retry Cleaner")
    activate_cleaner!(cleaner_id)
    booking_id = insert_booking!(customer_id, cleaner_id, "confirmed")

    Repo.query!(
      """
      UPDATE public.bookings
      SET direct_assigned_cleaner_id = $2,
          cleaner_assigned_at = now() - interval '5 minutes',
          cleaner_accepted_at = now(),
          assignment_phase = 'accepted',
          assignment_hold_until = now() + interval '10 minutes',
          status = 'in_progress',
          booking_period = NULL
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(cleaner_id)]
    )

    Repo.query!(
      "UPDATE public.cleaner_data SET status = 'inactive' WHERE user_id = $1",
      [Ecto.UUID.dump!(cleaner_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.cleaner_availability_exceptions (cleaner_id, exception_date)
      VALUES ($1, '2030-09-13')
      """,
      [Ecto.UUID.dump!(cleaner_id)]
    )

    assert {:ok, assigned} =
             DirectAdminBookings.assign_cleaner(admin_id, booking_id, %{"cleanerId" => cleaner_id})

    assert assigned["cleanerId"] == cleaner_id
    assert assigned["directAssignedCleanerId"] == cleaner_id
    assert assigned["status"] == "in_progress"
    assert assigned["assignmentPhase"] == "accepted"
    assert assigned["cleanerAcceptedAt"]
    assert assigned["assignmentHoldUntil"]

    assert [[%DateTime{} = starts_at, %DateTime{} = ends_at]] =
             Repo.query!(
               "SELECT lower(booking_period), upper(booking_period) FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert DateTime.compare(starts_at, ~U[2030-09-13 08:00:00Z]) == :eq
    assert DateTime.compare(ends_at, ~U[2030-09-13 12:00:00Z]) == :eq
  end

  test "reassignment clears stale cleaner acceptance state" do
    admin_id = insert_admin!()
    customer_id = insert_user!("customer5@example.com", "+233500000034")
    old_cleaner_id = insert_user!("old@example.com", "+233500000035", "Old Cleaner")
    new_cleaner_id = insert_user!("new@example.com", "+233500000036", "New Cleaner")
    activate_cleaner!(new_cleaner_id)
    booking_id = insert_booking!(customer_id, old_cleaner_id, "confirmed")

    Repo.query!(
      """
      UPDATE public.bookings
      SET direct_assigned_cleaner_id = $2,
          cleaner_accepted_at = now(),
          assignment_phase = 'accepted',
          assignment_hold_until = now() + interval '10 minutes'
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(old_cleaner_id)]
    )

    assert {:ok, assigned} =
             DirectAdminBookings.assign_cleaner(admin_id, booking_id, %{
               "cleanerId" => new_cleaner_id
             })

    assert assigned["cleanerId"] == new_cleaner_id
    assert assigned["directAssignedCleanerId"] == new_cleaner_id
    assert is_nil(assigned["cleanerAcceptedAt"])
    assert is_nil(assigned["assignmentPhase"])
    assert is_nil(assigned["assignmentHoldUntil"])
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
        currency, booking_period
      ) VALUES (
        $1, $2, $3, 1, $4, 'paid', '2030-09-13', '08:00', 4, 'Africa/Accra',
        'Shell Signboard, Spintex Rd, Accra, Ghana', NULL, 28166, 28166, 22841, 'GHS',
        tstzrange('2030-09-13 08:00:00+00', '2030-09-13 12:00:00+00', '[)')
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

  defp activate_cleaner!(cleaner_id) do
    uid = Ecto.UUID.dump!(cleaner_id)

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'cleaner')", [uid])

    Repo.query!(
      """
      INSERT INTO public.cleaner_data (user_id, verified, status, hourly_rate, specialties)
      VALUES ($1, true, 'active', 50, ARRAY['cleaning'])
      """,
      [uid]
    )
  end

  defp dump_optional(nil), do: nil
  defp dump_optional(id), do: Ecto.UUID.dump!(id)
end
