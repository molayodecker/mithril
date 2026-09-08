defmodule Mithril.DirectDispatchListTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectDispatch
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate dispatch list fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["direct_service_requests", "profiles", "user_roles", "users"] do
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
    CREATE TABLE public.direct_service_requests (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      kind text NOT NULL,
      status text NOT NULL,
      priority text NOT NULL,
      role text,
      requested_start_at timestamptz,
      duration_hours numeric,
      household_address_snapshot text NOT NULL,
      related_booking_id uuid,
      related_service_id integer,
      requirements jsonb NOT NULL DEFAULT '{}'::jsonb,
      notes text,
      admin_note text,
      assigned_worker_user_id uuid,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    :ok
  end

  test "admin queue exposes the related service for replacement dispatch" do
    admin_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()
    request_id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.users (id, email) VALUES ($1, 'ops@tryinstaclean.com')", [
      Ecto.UUID.dump!(admin_id)
    ])

    Repo.query!("INSERT INTO public.users (id, email) VALUES ($1, 'customer@example.com')", [
      Ecto.UUID.dump!(customer_id)
    ])

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    Repo.query!(
      """
      INSERT INTO public.direct_service_requests (
        id, customer_id, kind, status, priority, requested_start_at,
        duration_hours, household_address_snapshot, related_booking_id,
        related_service_id, requirements
      ) VALUES (
        $1, $2, 'replacement', 'submitted', 'same_day',
        '2026-09-09T10:00:00Z', 2, 'East Legon, Accra', $3, 7, '{}'::jsonb
      )
      """,
      [
        Ecto.UUID.dump!(request_id),
        Ecto.UUID.dump!(customer_id),
        Ecto.UUID.dump!(booking_id)
      ]
    )

    assert {:ok, [request]} = DirectDispatch.list_admin_service_requests(admin_id)
    assert request["relatedBookingId"] == booking_id
    assert request["relatedServiceId"] == 7
  end
end
