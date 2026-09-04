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

    for table <- [
          "kyc_profiles",
          "placement_matches",
          "placement_candidate_profiles",
          "cleaner_data",
          "profiles",
          "users",
          "household_workers",
          "placement_requests",
          "user_roles"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

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
      lastname text,
      avatar_url text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY,
      verified boolean NOT NULL DEFAULT false,
      status text NOT NULL DEFAULT 'inactive',
      rating numeric,
      completed_jobs integer NOT NULL DEFAULT 0
    )
    """)

    Repo.query!("""
    CREATE TABLE public.placement_candidate_profiles (
      user_id uuid PRIMARY KEY,
      placement_opt_in boolean NOT NULL DEFAULT false,
      placement_status text NOT NULL DEFAULT 'inactive',
      desired_roles text[],
      years_experience integer,
      bio text,
      preferred_languages text[],
      available_from date,
      updated_at timestamptz NOT NULL DEFAULT now()
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
    CREATE TABLE public.placement_matches (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      placement_request_id uuid NOT NULL,
      candidate_user_id uuid NOT NULL,
      status text NOT NULL DEFAULT 'suggested',
      customer_visible_note text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (placement_request_id, candidate_user_id)
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
      placement_request_id uuid,
      placement_match_id uuid,
      role text,
      start_date date,
      salary_frequency text,
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
             Direct.create_placement(customer_id, valid_placement_params())

    assert {:ok, [placement]} = Direct.list_placements(customer_id)
    assert placement["id"] == placement_id
    assert placement["status"] == "submitted"
    assert placement["role"] == "househelp"
  end

  test "placement creation rejects an invalid desired start date before SQL casting" do
    customer_id = Ecto.UUID.generate()
    params = Map.put(valid_placement_params(), "desiredStartDate", "2026-02-30")

    assert {:error, :invalid_desired_start_date} = Direct.create_placement(customer_id, params)
    assert [[0]] = Repo.query!("SELECT count(*) FROM public.placement_requests").rows
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

  test "private helper creation rejects an invalid start date before SQL casting" do
    customer_id = Ecto.UUID.generate()

    params = %{
      "firstName" => "Ama",
      "phone" => "+233200000001",
      "role" => "nanny",
      "startDate" => "2026-13-01",
      "liveIn" => false
    }

    assert {:error, :invalid_start_date} = Direct.add_private_helper(customer_id, params)
    assert [[0]] = Repo.query!("SELECT count(*) FROM public.household_workers").rows
  end

  test "admin endpoints reject a non-admin canonical user" do
    user_id = Ecto.UUID.generate()

    assert {:error, :forbidden} = Direct.list_admin_placements(user_id)
  end

  test "admin endpoints authorize from canonical user_roles" do
    user_id = Ecto.UUID.generate()
    insert_placement(Ecto.UUID.generate(), "gardener", "Labone")
    insert_admin(user_id)

    assert {:ok, [placement]} = Direct.list_admin_placements(user_id)
    assert placement["role"] == "gardener"
  end

  test "admin matching appends the placement role when desired_roles is null" do
    admin_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()
    placement_id = insert_placement(Ecto.UUID.generate(), "nanny", "East Legon")

    insert_admin(admin_id)
    insert_candidate(candidate_id, desired_roles: nil, opt_in: false, placement_status: "inactive")

    assert {:ok, %{matchId: match_id}} =
             Direct.match_admin_candidate(admin_id, placement_id, %{
               "candidateUserId" => candidate_id,
               "consentConfirmed" => true
             })

    assert is_binary(match_id)

    assert [[true, "available", ["nanny"]]] =
             Repo.query!(
               "SELECT placement_opt_in, placement_status, desired_roles FROM public.placement_candidate_profiles WHERE user_id = $1",
               [Ecto.UUID.dump!(candidate_id)]
             ).rows
  end

  test "hiring refreshes and reactivates an existing linked household worker" do
    customer_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()

    placement_id =
      insert_placement(customer_id, "nanny", "Airport Residential",
        living_arrangement: "live_in",
        desired_start_date: "2026-09-20",
        salary_frequency: "monthly"
      )

    insert_candidate(candidate_id,
      desired_roles: ["nanny"],
      opt_in: true,
      placement_status: "available",
      first_name: "Akosua",
      last_name: "Owusu",
      phone: "+233200000099",
      email: "akosua@example.com"
    )

    match_id = insert_match(placement_id, candidate_id)

    [[existing_worker_id]] =
      Repo.query!(
        """
        INSERT INTO public.household_workers (
          household_owner_id,
          worker_user_id,
          first_name,
          last_name,
          phone,
          email,
          source,
          role,
          live_in,
          status,
          invitation_status
        ) VALUES ($1, $2, 'Old', 'Name', '+233200000000', 'old@example.com',
                  'customer_invited', 'cook', false, 'inactive', 'not_sent')
        RETURNING id::text
        """,
        [Ecto.UUID.dump!(customer_id), Ecto.UUID.dump!(candidate_id)]
      ).rows

    assert {:ok, %{householdWorkerId: ^existing_worker_id}} =
             Direct.hire_match(customer_id, match_id)

    assert [
             [
               ^existing_worker_id,
               "Akosua",
               "Owusu",
               "+233200000099",
               "akosua@example.com",
               "instaclean_placement",
               ^placement_id,
               ^match_id,
               "nanny",
               "2026-09-20",
               "monthly",
               true,
               "active",
               "accepted"
             ]
           ] =
             Repo.query!(
               """
               SELECT
                 id::text,
                 first_name,
                 last_name,
                 phone,
                 email,
                 source,
                 placement_request_id::text,
                 placement_match_id::text,
                 role,
                 start_date::text,
                 salary_frequency,
                 live_in,
                 status,
                 invitation_status
               FROM public.household_workers
               WHERE id::text = $1
               """,
               [existing_worker_id]
             ).rows

    assert [["placed"]] =
             Repo.query!("SELECT status FROM public.placement_requests WHERE id::text = $1", [
               placement_id
             ]).rows

    assert [["hired"]] =
             Repo.query!("SELECT status FROM public.placement_matches WHERE id::text = $1", [
               match_id
             ]).rows
  end

  defp valid_placement_params do
    %{
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
    }
  end

  defp insert_admin(user_id) do
    Repo.query!(
      "INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')",
      [Ecto.UUID.dump!(user_id)]
    )
  end

  defp insert_candidate(candidate_id, opts) do
    first_name = Keyword.get(opts, :first_name, "Ama")
    last_name = Keyword.get(opts, :last_name, "Mensah")
    phone = Keyword.get(opts, :phone, "+233200000010")
    email = Keyword.get(opts, :email, "candidate@example.com")
    opt_in = Keyword.get(opts, :opt_in, true)
    placement_status = Keyword.get(opts, :placement_status, "available")
    desired_roles = Keyword.get(opts, :desired_roles, ["nanny"])
    candidate_uuid = Ecto.UUID.dump!(candidate_id)

    Repo.query!(
      "INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)",
      [candidate_uuid, email, phone]
    )

    Repo.query!(
      "INSERT INTO public.profiles (id, firstname, lastname, fullname) VALUES ($1, $2, $3, $4)",
      [candidate_uuid, first_name, last_name, "#{first_name} #{last_name}"]
    )

    Repo.query!(
      "INSERT INTO public.cleaner_data (user_id, verified, status, rating, completed_jobs) VALUES ($1, true, 'active', 5, 12)",
      [candidate_uuid]
    )

    Repo.query!(
      """
      INSERT INTO public.placement_candidate_profiles (
        user_id, placement_opt_in, placement_status, desired_roles
      ) VALUES ($1, $2, $3, $4)
      """,
      [candidate_uuid, opt_in, placement_status, desired_roles]
    )
  end

  defp insert_match(placement_id, candidate_id) do
    [[match_id]] =
      Repo.query!(
        """
        INSERT INTO public.placement_matches (
          placement_request_id, candidate_user_id, status
        ) VALUES ($1, $2, 'suggested')
        RETURNING id::text
        """,
        [Ecto.UUID.dump!(placement_id), Ecto.UUID.dump!(candidate_id)]
      ).rows

    match_id
  end

  defp insert_placement(customer_id, role, address, opts \\ []) do
    living_arrangement = Keyword.get(opts, :living_arrangement, "flexible")
    desired_start_date = Keyword.get(opts, :desired_start_date, "")
    salary_frequency = Keyword.get(opts, :salary_frequency, "")

    [[placement_id]] =
      Repo.query!(
        """
        INSERT INTO public.placement_requests (
          customer_id,
          status,
          role,
          living_arrangement,
          employment_type,
          desired_start_date,
          salary_frequency,
          household_address_snapshot
        ) VALUES ($1, 'submitted', $2, $3, 'flexible', NULLIF($4::text, '')::date,
                  NULLIF($5::text, ''), $6)
        RETURNING id::text
        """,
        [
          Ecto.UUID.dump!(customer_id),
          role,
          living_arrangement,
          desired_start_date,
          salary_frequency,
          address
        ]
      ).rows

    placement_id
  end
end
