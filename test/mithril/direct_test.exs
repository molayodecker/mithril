defmodule Mithril.DirectTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Direct
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate Direct fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.household_workers")
    Repo.query!("DROP TABLE IF EXISTS public.placement_requests")
    Repo.query!("DROP TABLE IF EXISTS public.user_roles")

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.placement_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id uuid NOT NULL,
      status text NOT NULL DEFAULT 'submitted',
      role text NOT NULL,
      living_arrangement text NOT NULL,
      employment_type text NOT NULL,
      desired_start_date date,
      salary_min_pesewas integer,
      salary_max_pesewas integer,
      salary_frequency text,
      household_address_snapshot text NOT NULL,
      requirements jsonb NOT NULL DEFAULT '{}'::jsonb,
      notes text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.household_workers (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      household_owner_id uuid NOT NULL,
      worker_user_id uuid,
      first_name text NOT NULL,
      last_name text,
      phone text NOT NULL,
      email text,
      source text NOT NULL,
      role text,
      start_date date,
      live_in boolean NOT NULL DEFAULT false,
      status text NOT NULL DEFAULT 'active',
      invitation_status text NOT NULL DEFAULT 'not_sent',
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX household_workers_owner_unlinked_phone_uniq
      ON public.household_workers (household_owner_id, phone)
      WHERE worker_user_id IS NULL
    """)

    :ok
  end

  test "placement reads are scoped to the canonical customer id" do
    customer_id = Ecto.UUID.generate()
    other_customer_id = Ecto.UUID.generate()

    insert_placement(customer_id, "nanny", "East Legon")
    insert_placement(other_customer_id, "cook", "Cantonments")

    assert {:ok, [placement]} = Direct.list_placements(customer_id)
    assert placement["role"] == "nanny"
    assert placement["householdAddress"] == "East Legon"
  end

  test "customer placement creation writes through Mithril" do
    customer_id = Ecto.UUID.generate()

    assert {:ok, %{id: placement_id}} =
             Direct.create_placement(customer_id, %{
               "role" => "househelp",
               "livingArrangement" => "live_out",
               "employmentType" => "full_time",
               "desiredStartDate" => "2026-09-15",
               "salaryMinPesewas" => 200_000,
               "salaryMaxPesewas" => 300_000,
               "salaryFrequency" => "monthly",
               "householdAddress" => "Airport Residential, Accra",
               "requirements" => %{"children" => 2},
               "notes" => "Weekdays"
             })

    assert {:ok, [placement]} = Direct.list_placements(customer_id)
    assert placement["id"] == placement_id
    assert placement["status"] == "submitted"
    assert placement["role"] == "househelp"
  end

  test "private helper creation is idempotent per owner and phone" do
    customer_id = Ecto.UUID.generate()

    first = %{
      "firstName" => "Ama",
      "lastName" => "Mensah",
      "phone" => "+233200000001",
      "email" => "",
      "role" => "nanny",
      "startDate" => nil,
      "liveIn" => false
    }

    assert {:ok, %{householdWorkerId: first_id}} = Direct.add_private_helper(customer_id, first)

    assert {:ok, %{householdWorkerId: second_id}} =
             Direct.add_private_helper(customer_id, %{first | "firstName" => "Ama Serwaa"})

    assert first_id == second_id
    assert {:ok, [helper]} = Direct.list_helpers(customer_id)
    assert helper["firstName"] == "Ama Serwaa"
    assert helper["source"] == "customer_invited"
  end

  test "admin endpoints reject a non-admin canonical user" do
    user_id = Ecto.UUID.generate()

    assert {:error, :forbidden} = Direct.list_admin_placements(user_id)
  end

  test "admin endpoints authorize from canonical user_roles" do
    user_id = Ecto.UUID.generate()
    insert_placement(Ecto.UUID.generate(), "gardener", "Labone")

    Repo.query!(
      "INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')",
      [Ecto.UUID.dump!(user_id)]
    )

    assert {:ok, [placement]} = Direct.list_admin_placements(user_id)
    assert placement["role"] == "gardener"
  end

  defp insert_placement(customer_id, role, address) do
    Repo.query!(
      """
      INSERT INTO public.placement_requests (
        customer_id,
        status,
        role,
        living_arrangement,
        employment_type,
        household_address_snapshot
      ) VALUES ($1, 'submitted', $2, 'flexible', 'flexible', $3)
      """,
      [Ecto.UUID.dump!(customer_id), role, address]
    )
  end
end
