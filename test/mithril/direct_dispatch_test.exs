defmodule Mithril.DirectDispatchTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectDispatch
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate dispatch fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "direct_booking_origins",
          "direct_service_requests",
          "placement_candidate_profiles",
          "cleaner_data",
          "profiles",
          "user_roles",
          "bookings",
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
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      address text NOT NULL,
      scheduled_date date NOT NULL,
      scheduled_time time NOT NULL,
      duration_hours numeric NOT NULL,
      timezone text,
      status text NOT NULL DEFAULT 'pending'
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
    CREATE TABLE public.direct_booking_origins (
      booking_id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      created_by_user_id uuid NOT NULL,
      source text NOT NULL,
      consent_confirmed boolean NOT NULL,
      admin_note text,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    :ok
  end

  test "creates urgent household help and lists it for the customer" do
    customer_id = insert_user!("customer@example.com", "+233500000001")

    assert {:ok, created} =
             DirectDispatch.create_urgent_request(customer_id, %{
               "role" => "elder_caregiver",
               "priority" => "urgent",
               "neededBy" => "2026-09-07T15:00:00Z",
               "durationHours" => 6,
               "householdAddress" => "East Legon Hills, Accra",
               "requirements" => %{"mobilitySupport" => true},
               "notes" => "Non-medical companionship and mobility help"
             })

    assert created.kind == "urgent_help"
    assert created.status == "submitted"

    assert {:ok, [request]} = DirectDispatch.list_service_requests(customer_id)
    assert request["id"] == created.id
    assert request["role"] == "elder_caregiver"
    assert request["priority"] == "urgent"
    assert request["requirements"]["mobilitySupport"] == true
  end

  test "prevents duplicate active replacement requests for one booking" do
    customer_id = insert_user!("customer@example.com", "+233500000002")
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, address, scheduled_date, scheduled_time,
        duration_hours, timezone, status
      ) VALUES ($1, $2, 'Labone, Accra', '2026-09-08', '10:00', 3, 'Africa/Accra', 'pending')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id)]
    )

    assert {:ok, first} =
             DirectDispatch.request_replacement(customer_id, booking_id, %{
               "priority" => "same_day",
               "notes" => "Original professional cancelled"
             })

    assert first.kind == "replacement"

    assert {:error, :replacement_already_requested} =
             DirectDispatch.request_replacement(customer_id, booking_id, %{
               "priority" => "urgent"
             })
  end

  test "admin dispatch queue rejects non-admin users" do
    customer_id = insert_user!("customer@example.com", "+233500000003")

    assert {:error, :forbidden} = DirectDispatch.list_admin_service_requests(customer_id)
  end

  test "caregiver assignment requires an opted-in available candidate" do
    admin_id = insert_user!("ops@tryinstaclean.com", "+233500000004")
    customer_id = insert_user!("customer@example.com", "+233500000005")
    worker_id = insert_user!("worker@example.com", "+233500000006")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    Repo.query!(
      "INSERT INTO public.cleaner_data (user_id, verified, status) VALUES ($1, true, 'active')",
      [Ecto.UUID.dump!(worker_id)]
    )

    [[request_id]] =
      Repo.query!(
        """
        INSERT INTO public.direct_service_requests (
          customer_id, kind, status, priority, role, requested_start_at,
          duration_hours, household_address_snapshot, requirements, created_by_user_id
        ) VALUES ($1, 'urgent_help', 'submitted', 'urgent', 'elder_caregiver', now(), 4,
                  'Cantonments, Accra', '{}'::jsonb, $1)
        RETURNING id::text
        """,
        [Ecto.UUID.dump!(customer_id)]
      ).rows

    assert {:error, :candidate_unavailable} =
             DirectDispatch.assign_admin_service_request(admin_id, request_id, %{
               "workerUserId" => worker_id
             })

    Repo.query!(
      """
      INSERT INTO public.placement_candidate_profiles (
        user_id, placement_opt_in, placement_status, desired_roles
      ) VALUES ($1, true, 'available', ARRAY['elder_caregiver'])
      """,
      [Ecto.UUID.dump!(worker_id)]
    )

    assert {:ok, assigned} =
             DirectDispatch.assign_admin_service_request(admin_id, request_id, %{
               "workerUserId" => worker_id,
               "adminNote" => "Confirmed availability by phone"
             })

    assert assigned.status == "assigned"
    assert assigned.assignedWorkerUserId == worker_id
  end

  test "admin-assisted booking requires explicit customer consent" do
    admin_id = Ecto.UUID.generate()

    assert {:error, :consent_required} =
             DirectDispatch.create_admin_booking(admin_id, %{
               "customerUserId" => Ecto.UUID.generate(),
               "source" => "phone",
               "consentConfirmed" => false
             })
  end

  defp insert_user!(email, phone) do
    user_id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(user_id),
      email,
      phone
    ])

    user_id
  end
end
