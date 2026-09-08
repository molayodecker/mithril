defmodule Mithril.DirectDispatchAssignmentTimeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectDispatchSafety
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate dispatch timing fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.cleaner_has_booking_conflict(uuid, timestamptz, timestamptz, uuid)"
    )

    for table <- [
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
      timezone text
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
      status text NOT NULL DEFAULT 'inactive',
      hourly_rate numeric,
      specialties text[] NOT NULL DEFAULT '{}'::text[]
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
      previous_worker_user_id uuid,
      assigned_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_availability_exceptions (
      cleaner_id uuid NOT NULL,
      exception_date date NOT NULL
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
    AS $$ SELECT false $$
    """)

    :ok
  end

  test "rejects assignment when a queued request start has gone stale" do
    %{admin_id: admin_id, worker_id: worker_id, request_id: request_id} = fixture!()

    assert {:error, :needed_by_past} =
             DirectDispatchSafety.assign_admin_service_request(admin_id, request_id, %{
               "workerUserId" => worker_id
             })

    [[status, assigned_worker]] =
      Repo.query!(
        "SELECT status, assigned_worker_user_id FROM public.direct_service_requests WHERE id = $1",
        [Ecto.UUID.dump!(request_id)]
      ).rows

    assert status == "submitted"
    assert is_nil(assigned_worker)
  end

  test "admin assignment can move a stale request to a new future time" do
    %{admin_id: admin_id, worker_id: worker_id, request_id: request_id} = fixture!()
    future = DateTime.utc_now() |> DateTime.add(21_600, :second) |> DateTime.truncate(:second)

    assert {:ok, assigned} =
             DirectDispatchSafety.assign_admin_service_request(admin_id, request_id, %{
               "workerUserId" => worker_id,
               "neededBy" => DateTime.to_iso8601(future)
             })

    assert assigned.status == "assigned"
    assert assigned.assignedWorkerUserId == worker_id

    [[stored_start, status, assigned_worker]] =
      Repo.query!(
        "SELECT requested_start_at, status, assigned_worker_user_id FROM public.direct_service_requests WHERE id = $1",
        [Ecto.UUID.dump!(request_id)]
      ).rows

    assert DateTime.compare(stored_start, future) == :eq
    assert status == "assigned"
    assert assigned_worker == Ecto.UUID.dump!(worker_id)
  end

  defp fixture! do
    admin_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    request_id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    Repo.query!(
      "INSERT INTO public.cleaner_data (user_id, verified, status, hourly_rate) VALUES ($1, true, 'active', 100)",
      [Ecto.UUID.dump!(worker_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.direct_service_requests (
        id, customer_id, kind, status, priority, role, requested_start_at,
        duration_hours, household_address_snapshot, requirements, created_by_user_id
      ) VALUES ($1, $2, 'urgent_help', 'submitted', 'urgent', 'cleaner',
                now() - interval '5 minutes', 2, 'Labone, Accra', '{}'::jsonb, $2)
      """,
      [Ecto.UUID.dump!(request_id), Ecto.UUID.dump!(customer_id)]
    )

    %{admin_id: admin_id, worker_id: worker_id, request_id: request_id}
  end
end
