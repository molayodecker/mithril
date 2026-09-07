defmodule Mithril.DirectDispatchSafetyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectDispatchSafety
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate dispatch safety fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.cleaner_has_booking_conflict(uuid, timestamptz, timestamptz, uuid)"
    )

    for table <- [
          "test_cleaner_conflicts",
          "cleaner_availability_exceptions",
          "direct_service_requests",
          "placement_candidate_profiles",
          "cleaner_data",
          "user_roles",
          "bookings"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      service_id integer NOT NULL,
      address text NOT NULL,
      scheduled_date date NOT NULL,
      scheduled_time time NOT NULL,
      duration_hours numeric NOT NULL,
      timezone text,
      status text NOT NULL DEFAULT 'pending',
      payment_status text NOT NULL DEFAULT 'pending'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY,
      verified boolean NOT NULL DEFAULT false,
      status text NOT NULL DEFAULT 'inactive'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.placement_candidate_profiles (
      user_id uuid PRIMARY KEY,
      placement_opt_in boolean NOT NULL DEFAULT false,
      placement_status text NOT NULL DEFAULT 'inactive',
      desired_roles text[] NOT NULL DEFAULT '{}'::text[]
    )
    """)

    Repo.query!("""
    CREATE TABLE public.direct_service_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id uuid NOT NULL,
      kind text NOT NULL,
      status text NOT NULL DEFAULT 'submitted',
      priority text NOT NULL DEFAULT 'standard',
      role text,
      requested_start_at timestamptz,
      duration_hours numeric,
      household_address_snapshot text NOT NULL,
      related_booking_id uuid,
      related_service_id integer,
      requirements jsonb NOT NULL DEFAULT '{}'::jsonb,
      notes text,
      admin_note text,
      created_by_user_id uuid NOT NULL,
      assigned_worker_user_id uuid,
      assigned_by_user_id uuid,
      assigned_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX direct_service_requests_active_replacement_uniq
      ON public.direct_service_requests (related_booking_id)
      WHERE kind = 'replacement'
        AND status IN ('submitted', 'triaging', 'matching', 'assigned')
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_availability_exceptions (
      cleaner_id uuid NOT NULL,
      exception_date date NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.test_cleaner_conflicts (
      cleaner_id uuid NOT NULL,
      starts_at timestamptz NOT NULL,
      ends_at timestamptz NOT NULL
    )
    """)

    Repo.query!("""
    CREATE FUNCTION public.cleaner_has_booking_conflict(
      p_cleaner_id uuid,
      p_start timestamptz,
      p_end timestamptz,
      p_exclude_booking_id uuid
    ) RETURNS boolean
    LANGUAGE sql
    AS $$
      SELECT EXISTS (
        SELECT 1
        FROM public.test_cleaner_conflicts c
        WHERE c.cleaner_id = p_cleaner_id
          AND tstzrange(c.starts_at, c.ends_at, '[)') && tstzrange(p_start, p_end, '[)')
      )
    $$
    """)

    :ok
  end

  test "rejects replacement requests for unpaid bookings" do
    customer_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()

    insert_booking!(booking_id, customer_id, "pending")

    assert {:error, :booking_unpaid} =
             DirectDispatchSafety.request_replacement(customer_id, booking_id, %{
               "priority" => "same_day"
             })

    assert Repo.query!("SELECT count(*) FROM public.direct_service_requests").rows == [[0]]
  end

  test "allows a replacement request once the owned booking is paid" do
    customer_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()

    insert_booking!(booking_id, customer_id, "paid")

    assert {:ok, request} =
             DirectDispatchSafety.request_replacement(customer_id, booking_id, %{
               "priority" => "same_day",
               "notes" => "Original worker cancelled"
             })

    assert request.kind == "replacement"
    assert request.relatedBookingId == booking_id
  end

  test "rejects dispatch assignment on a worker availability exception" do
    %{admin_id: admin_id, worker_id: worker_id, request_id: request_id} = dispatch_fixture!()

    Repo.query!(
      "INSERT INTO public.cleaner_availability_exceptions (cleaner_id, exception_date) VALUES ($1, '2026-09-08')",
      [Ecto.UUID.dump!(worker_id)]
    )

    assert {:error, :candidate_unavailable} =
             DirectDispatchSafety.assign_admin_service_request(admin_id, request_id, %{
               "workerUserId" => worker_id
             })
  end

  test "rejects dispatch assignment when the worker has a buffered booking conflict" do
    %{admin_id: admin_id, worker_id: worker_id, request_id: request_id} = dispatch_fixture!()

    Repo.query!(
      """
      INSERT INTO public.test_cleaner_conflicts (cleaner_id, starts_at, ends_at)
      VALUES ($1, '2026-09-08T09:30:00Z', '2026-09-08T11:00:00Z')
      """,
      [Ecto.UUID.dump!(worker_id)]
    )

    assert {:error, :candidate_unavailable} =
             DirectDispatchSafety.assign_admin_service_request(admin_id, request_id, %{
               "workerUserId" => worker_id
             })
  end

  test "delegates assignment when the worker is eligible and schedule-safe" do
    %{admin_id: admin_id, worker_id: worker_id, request_id: request_id} = dispatch_fixture!()

    assert {:ok, assigned} =
             DirectDispatchSafety.assign_admin_service_request(admin_id, request_id, %{
               "workerUserId" => worker_id,
               "adminNote" => "Confirmed available"
             })

    assert assigned.status == "assigned"
    assert assigned.assignedWorkerUserId == worker_id
  end

  defp insert_booking!(booking_id, customer_id, payment_status) do
    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, service_id, address, scheduled_date, scheduled_time,
        duration_hours, timezone, status, payment_status
      ) VALUES ($1, $2, 1, 'Labone, Accra', '2026-09-08', '10:00', 3,
                'Africa/Accra', 'pending', $3)
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), payment_status]
    )
  end

  defp dispatch_fixture! do
    admin_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    Repo.query!(
      "INSERT INTO public.cleaner_data (user_id, verified, status) VALUES ($1, true, 'active')",
      [Ecto.UUID.dump!(worker_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.placement_candidate_profiles (
        user_id, placement_opt_in, placement_status, desired_roles
      ) VALUES ($1, true, 'available', ARRAY['elder_caregiver'])
      """,
      [Ecto.UUID.dump!(worker_id)]
    )

    [[request_id]] =
      Repo.query!(
        """
        INSERT INTO public.direct_service_requests (
          customer_id, kind, status, priority, role, requested_start_at,
          duration_hours, household_address_snapshot, requirements, created_by_user_id
        ) VALUES ($1, 'urgent_help', 'submitted', 'urgent', 'elder_caregiver',
                  '2026-09-08T10:00:00Z', 4, 'Cantonments, Accra', '{}'::jsonb, $1)
        RETURNING id::text
        """,
        [Ecto.UUID.dump!(customer_id)]
      ).rows

    %{admin_id: admin_id, customer_id: customer_id, worker_id: worker_id, request_id: request_id}
  end
end
