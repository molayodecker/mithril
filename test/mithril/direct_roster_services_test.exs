defmodule Mithril.DirectRosterServicesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Direct
  alias Mithril.DirectOperations
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate roster fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "cleaner_applications",
          "placement_candidate_profiles",
          "cleaner_data",
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
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY,
      status text NOT NULL DEFAULT 'active',
      verified boolean NOT NULL DEFAULT false,
      rating numeric,
      completed_jobs integer,
      hourly_rate numeric,
      specialties text[] NOT NULL DEFAULT ARRAY[]::text[],
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_applications (
      id uuid PRIMARY KEY,
      user_id uuid,
      status text,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.placement_candidate_profiles (
      user_id uuid PRIMARY KEY,
      placement_opt_in boolean,
      placement_status text,
      desired_roles text[]
    )
    """)

    :ok
  end

  test "a reviewer can read roster services" do
    reviewer_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()

    insert_user!(reviewer_id, "irene@tryinstaclean.com", "reviewer")
    insert_user!(worker_id, "worker@tryinstaclean.com", nil)

    Repo.query!(
      """
      INSERT INTO public.profiles (id, fullname)
      VALUES ($1::uuid, 'Irene Worker')
      """,
      [Ecto.UUID.dump!(worker_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.cleaner_data (user_id, status, verified, specialties)
      VALUES ($1::uuid, 'active', true, ARRAY['ironing', 'window_cleaning']::text[])
      """,
      [Ecto.UUID.dump!(worker_id)]
    )

    assert {:error, :forbidden} =
             DirectOperations.list_cleaners(reviewer_id, %{
               "status" => "active",
               "verified" => true
             })

    assert {:ok, candidates} = Direct.list_admin_candidates(reviewer_id)
    candidate = Enum.find(candidates, &(&1["userId"] == worker_id))
    assert candidate["specialties"] == ["ironing", "window_cleaning"]
  end

  test "a customer cannot read the cleaner roster" do
    customer_id = Ecto.UUID.generate()
    insert_user!(customer_id, "customer@tryinstaclean.com", "customer")

    assert {:error, :forbidden} = DirectOperations.list_cleaners(customer_id, %{})
    assert {:error, :forbidden} = Direct.list_admin_candidates(customer_id)
  end

  defp insert_user!(id, email, role) do
    Repo.query!("INSERT INTO public.users (id, email) VALUES ($1::uuid, $2)", [
      Ecto.UUID.dump!(id),
      email
    ])

    if role do
      Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1::uuid, $2)", [
        Ecto.UUID.dump!(id),
        role
      ])
    end
  end
end
