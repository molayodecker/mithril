defmodule Mithril.DirectAdminCleanerApplicationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Direct
  alias Mithril.Repo

  @admin "11111111-1111-4111-8111-111111111111"
  @worker "22222222-2222-4222-8222-222222222222"
  @application "33333333-3333-4333-8333-333333333333"
  @weekly "44444444-4444-4444-8444-444444444444"

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate application fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["kyc_profiles", "cleaner_applications", "user_roles", "users"] do
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
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_applications (
      id uuid PRIMARY KEY,
      user_id uuid,
      name text NOT NULL,
      email text,
      phone text,
      status text,
      kyc_status text,
      kyc_review_answer text,
      kyc_review_status text,
      kyc_completed_at timestamptz,
      sumsub_applicant_id text,
      sumsub_level_name text,
      hourly_rate numeric NOT NULL,
      skills text[],
      created_at timestamptz,
      bio text,
      applicant_bio text,
      languages text[],
      service_areas text[],
      years_of_experience text,
      hours_per_week text,
      certifications text[],
      admin_feedback text,
      has_cleaning_experience boolean,
      previous_employers text,
      client_description text,
      additional_skills text[],
      available_days text[],
      availability jsonb,
      reference1_name text,
      reference1_phone text,
      reference1_relationship text,
      reference2_name text,
      reference2_phone text,
      reference2_relationship text,
      reference3_name text,
      reference3_phone text,
      reference3_relationship text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.kyc_profiles (
      id uuid PRIMARY KEY,
      user_id uuid,
      kyc_status text,
      review_answer text,
      review_reason text,
      reviewed_at timestamptz,
      completed_at timestamptz,
      submitted_at timestamptz,
      sumsub_applicant_id text,
      level_name text,
      document_types text[],
      last_event_type text,
      updated_at timestamptz,
      created_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.cleaner_data (
      user_id uuid PRIMARY KEY
    )
    """)

    Repo.query!("INSERT INTO public.users (id) VALUES ($1::uuid)", [Ecto.UUID.dump!(@admin)])

    Repo.query!(
      "INSERT INTO public.user_roles (user_id, role_id) VALUES ($1::uuid, 'admin')",
      [Ecto.UUID.dump!(@admin)]
    )

    :ok
  end

  test "application detail includes experience, availability, guarantors, and the real Sumsub profile" do
    insert_application(@application, @worker, %{
      years: "1-2",
      hours: "20-40",
      experience: true,
      employers: "A previous household",
      client: "Professional and trustworthy",
      skills: ["Have you cleaned offices?"],
      days: ["monday", "friday"],
      availability: %{
        "availableDays" => ["monday"],
        "preferredShifts" => ["morning"],
        "startDate" => "21 Sept 2026"
      },
      reference1_name: "Ama Mensah",
      reference1_phone: "0244000000",
      reference1_relationship: "Former client"
    })

    Repo.query!(
      """
      INSERT INTO public.kyc_profiles (
        id, user_id, kyc_status, review_answer, review_reason, reviewed_at, completed_at,
        submitted_at, sumsub_applicant_id, level_name, document_types, last_event_type,
        updated_at, created_at
      ) VALUES (
        $1::uuid, $2::uuid, 'completed', 'GREEN', NULL, '2026-09-02T00:00:00Z',
        '2026-09-02T00:00:00Z', '2026-09-01T00:00:00Z', 'applicant-real', 'id-and-liveness',
        ARRAY['PASSPORT'], 'applicantReviewed', '2026-09-02T00:00:00Z', '2026-09-01T00:00:00Z'
      )
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(@worker)]
    )

    Repo.query!(
      """
      INSERT INTO public.kyc_profiles (
        id, user_id, kyc_status, sumsub_applicant_id, updated_at, created_at
      ) VALUES (
        $1::uuid, $2::uuid, 'not_started', '', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z'
      )
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(@worker)]
    )

    assert {:ok, detail} = Direct.get_admin_cleaner_application(@admin, @application)
    assert detail["hasCleaningExperience"] == true
    assert detail["yearsOfExperience"] == "1-2"
    assert detail["previousEmployers"] == "A previous household"
    assert detail["clientDescription"] == "Professional and trustworthy"
    assert detail["additionalSkills"] == ["Have you cleaned offices?"]
    assert detail["hoursPerWeek"] == "20-40"
    assert detail["availableDays"] == ["monday", "friday"]
    assert detail["preferredShifts"] == ["morning"]
    assert detail["availabilityStart"] == "21 Sept 2026"
    assert detail["weeklyAvailability"] == []

    assert Enum.at(detail["guarantors"], 0) == %{
             "label" => "Guarantor 1",
             "name" => "Ama Mensah",
             "phone" => "0244000000",
             "relationship" => "Former client"
           }

    assert Enum.at(detail["guarantors"], 1)["name"] == nil
    assert detail["kycStatus"] == "completed"
    assert detail["kyc"]["source"] == "kyc_profiles"
    assert detail["kyc"]["status"] == "completed"
    assert detail["kyc"]["reviewAnswer"] == "GREEN"
    assert detail["kyc"]["applicantId"] == "applicant-real"
    assert detail["kyc"]["levelName"] == "id-and-liveness"
    assert detail["kyc"]["documentTypes"] == ["PASSPORT"]

    listed = listed_application(@application)
    assert listed["kycStatus"] == "completed"
    assert listed["kycReviewAnswer"] == "GREEN"
  end

  test "weekly availability and application KYC are used when no Sumsub profile exists" do
    insert_application(@weekly, nil, %{
      availability: %{
        "monday" => %{"available" => true, "start" => "08:00", "end" => "12:00"},
        "tuesday" => %{"available" => false}
      },
      kyc_status: "pending",
      kyc_review_answer: "green",
      kyc_review_status: "pending",
      sumsub_applicant_id: "applicant-on-form",
      sumsub_level_name: "basic"
    })

    assert {:ok, detail} = Direct.get_admin_cleaner_application(@admin, @weekly)
    assert detail["availableDays"] == []

    assert detail["weeklyAvailability"] == [
             %{
               "day" => "monday",
               "available" => true,
               "start" => "08:00",
               "end" => "12:00"
             },
             %{
               "day" => "tuesday",
               "available" => false,
               "start" => nil,
               "end" => nil
             }
           ]

    assert detail["kyc"]["source"] == "cleaner_applications"
    assert detail["kyc"]["status"] == "pending"
    assert detail["kyc"]["reviewAnswer"] == "GREEN"
    assert detail["kyc"]["reviewStatus"] == "pending"
    assert detail["kyc"]["applicantId"] == "applicant-on-form"
    assert detail["kyc"]["levelName"] == "basic"
    assert detail["kyc"]["documentTypes"] == []
  end

  test "ignores newer reviews at unrelated Sumsub levels" do
    insert_application(@application, @worker, %{kyc_status: "pending"})

    insert_kyc_profile(@worker, "id-and-liveness", "rejected", "RED", "worker-review")
    insert_kyc_profile(@worker, "basic-kyc", "completed", "GREEN", "unrelated-review")

    assert {:ok, detail} = Direct.get_admin_cleaner_application(@admin, @application)
    assert detail["kyc"]["source"] == "kyc_profiles"
    assert detail["kyc"]["status"] == "rejected"
    assert detail["kyc"]["reviewAnswer"] == "RED"
    assert detail["kyc"]["applicantId"] == "worker-review"

    listed = listed_application(@application)
    assert listed["kycStatus"] == "rejected"
    assert listed["kycReviewAnswer"] == "RED"
  end

  test "falls back to application review when only empty worker profiles exist" do
    insert_application(@application, @worker, %{
      kyc_status: "completed",
      kyc_review_answer: "GREEN",
      sumsub_applicant_id: "application-review",
      sumsub_level_name: "id-and-liveness"
    })

    Repo.query!(
      """
      INSERT INTO public.kyc_profiles (id, user_id, kyc_status, level_name, updated_at, created_at)
      VALUES ($1::uuid, $2::uuid, 'not_started', 'id-and-liveness', now(), now())
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(@worker)]
    )

    assert {:ok, detail} = Direct.get_admin_cleaner_application(@admin, @application)
    assert detail["kyc"]["source"] == "cleaner_applications"
    assert detail["kyc"]["status"] == "completed"
    assert detail["kyc"]["reviewAnswer"] == "GREEN"
    assert detail["kyc"]["applicantId"] == "application-review"
  end

  test "search, sort, and the next page reach applications outside the first 50" do
    Enum.each(1..51, fn n ->
      name = if n == 1, do: "Needle Person", else: "Page Person #{n}"
      status = if n == 2, do: "rejected", else: "pending"
      created_at = if n == 1, do: ~U[2026-01-01 00:00:00Z], else: ~U[2026-11-01 00:00:00Z]

      Repo.query!(
        """
        INSERT INTO public.cleaner_applications (id, name, status, hourly_rate, skills, email, created_at)
        VALUES ($1::uuid, $2, $3, 40, ARRAY['Window']::text[], $4, $5)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          name,
          status,
          "page_#{n}@tryinstaclean.com",
          created_at
        ]
      )
    end)

    assert {:ok, first} = Direct.list_admin_cleaner_applications(@admin)
    assert first["limit"] == 50
    assert first["page"] == 1
    assert first["directoryTotal"] == 51
    assert first["total"] == 51
    assert length(first["applications"]) == 50
    refute Enum.any?(first["applications"], &(&1["name"] == "Needle Person"))

    assert {:ok, second} = Direct.list_admin_cleaner_applications(@admin, %{"page" => "2"})
    assert Enum.map(second["applications"], & &1["name"]) == ["Needle Person"]

    assert {:ok, found} = Direct.list_admin_cleaner_applications(@admin, %{"q" => "needle"})
    assert found["total"] == 1
    assert hd(found["applications"])["name"] == "Needle Person"
    assert found["counts"]["all"] == 1

    assert {:ok, literal_email} =
             Direct.list_admin_cleaner_applications(@admin, %{
               "q" => "page_1@tryinstaclean.com"
             })

    assert literal_email["total"] == 1
    assert hd(literal_email["applications"])["email"] == "page_1@tryinstaclean.com"

    assert {:ok, wildcard} =
             Direct.list_admin_cleaner_applications(@admin, %{"q" => "page%1@"})

    assert wildcard["total"] == 0

    assert {:ok, rejected} =
             Direct.list_admin_cleaner_applications(@admin, %{"status" => "rejected"})

    assert rejected["total"] == 1
    assert hd(rejected["applications"])["name"] == "Page Person 2"
    assert rejected["counts"]["rejected"] == 1
    assert rejected["counts"]["all"] == 51

    assert {:ok, started} =
             Direct.list_admin_cleaner_applications(@admin, %{
               "startedFrom" => "2026-01-01",
               "startedTo" => "2026-01-02"
             })

    assert started["total"] == 1
    assert hd(started["applications"])["name"] == "Needle Person"

    assert {:ok, by_name} = Direct.list_admin_cleaner_applications(@admin, %{"sort" => "name"})
    assert hd(by_name["applications"])["name"] == "Needle Person"

    assert {:error, :invalid_request} =
             Direct.list_admin_cleaner_applications(@admin, %{"sort" => "email"})
  end

  test "search, step, and the next page reach drafts outside the first 50" do
    Repo.query!("DROP TABLE IF EXISTS public.cleaner_application_drafts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.profiles CASCADE")

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      lastname text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_application_drafts (
      id uuid PRIMARY KEY,
      user_id uuid,
      email text,
      payload jsonb NOT NULL DEFAULT '{}'::jsonb,
      current_step integer NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      last_saved_at timestamptz
    )
    """)

    Enum.each(1..51, fn n ->
      id = Ecto.UUID.generate()
      name = if n == 1, do: "Needle", else: "Draft"
      step = if n == 3, do: 3, else: 1
      created_at = if n == 1, do: ~U[2026-01-01 00:00:00Z], else: ~U[2026-11-01 00:00:00Z]

      Repo.query!(
        """
        INSERT INTO public.users (id, email) VALUES ($1::uuid, $2)
        """,
        [Ecto.UUID.dump!(id), "draft_#{n}@tryinstaclean.com"]
      )

      Repo.query!(
        """
        INSERT INTO public.cleaner_application_drafts (
          id, user_id, email, payload, current_step, created_at, updated_at, last_saved_at
        ) VALUES (
          $1::uuid, $2::uuid, $3, jsonb_build_object('firstName', $4::text, 'lastName', 'Person'), $5, $6, $6, $6
        )
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(id),
          "draft_#{n}@tryinstaclean.com",
          name,
          step,
          created_at
        ]
      )
    end)

    assert {:ok, first} = Direct.list_admin_cleaner_application_drafts(@admin)
    assert first["limit"] == 50
    assert length(first["drafts"]) == 50
    assert first["directoryTotal"] == 51
    refute Enum.any?(first["drafts"], &(&1["name"] == "Needle Person"))

    assert {:ok, second} = Direct.list_admin_cleaner_application_drafts(@admin, %{"page" => 2})
    assert Enum.map(second["drafts"], & &1["name"]) == ["Needle Person"]

    assert {:ok, found} = Direct.list_admin_cleaner_application_drafts(@admin, %{"q" => "needle"})
    assert found["total"] == 1
    assert hd(found["drafts"])["name"] == "Needle Person"

    assert {:ok, literal_email} =
             Direct.list_admin_cleaner_application_drafts(@admin, %{
               "q" => "draft_1@tryinstaclean.com"
             })

    assert literal_email["total"] == 1
    assert hd(literal_email["drafts"])["email"] == "draft_1@tryinstaclean.com"

    assert {:ok, wildcard} =
             Direct.list_admin_cleaner_application_drafts(@admin, %{"q" => "draft%1@"})

    assert wildcard["total"] == 0

    assert {:ok, step} = Direct.list_admin_cleaner_application_drafts(@admin, %{"step" => "3"})
    assert step["total"] == 1
    assert step["counts"]["all"] == 51
    assert Enum.any?(step["counts"]["steps"], &(&1["step"] == 3 and &1["count"] == 1))
  end

  test "approved workers and roster workers stay out of the draft queue" do
    Repo.query!("DROP TABLE IF EXISTS public.cleaner_application_drafts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.profiles CASCADE")

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      lastname text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_application_drafts (
      id uuid PRIMARY KEY,
      user_id uuid,
      email text,
      payload jsonb NOT NULL DEFAULT '{}'::jsonb,
      current_step integer NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      last_saved_at timestamptz
    )
    """)

    open_id = Ecto.UUID.generate()
    approved_id = Ecto.UUID.generate()
    roster_id = Ecto.UUID.generate()
    email_id = Ecto.UUID.generate()
    now = ~U[2026-11-01 00:00:00Z]

    for {id, email} <- [
          {open_id, "open@tryinstaclean.com"},
          {approved_id, "approved@tryinstaclean.com"},
          {roster_id, "roster@tryinstaclean.com"},
          {email_id, "approved@tryinstaclean.com"}
        ] do
      Repo.query!("INSERT INTO public.users (id, email) VALUES ($1::uuid, $2)", [
        Ecto.UUID.dump!(id),
        email
      ])
    end

    Repo.query!(
      """
      INSERT INTO public.cleaner_applications (id, user_id, name, email, status, hourly_rate)
      VALUES ($1::uuid, $2::uuid, 'Approved Person', 'approved@tryinstaclean.com', 'approved', 10)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(approved_id)]
    )

    Repo.query!("INSERT INTO public.cleaner_data (user_id) VALUES ($1::uuid)", [
      Ecto.UUID.dump!(roster_id)
    ])

    for {id, email, name} <- [
          {open_id, "open@tryinstaclean.com", "Open"},
          {approved_id, "approved@tryinstaclean.com", "Approved"},
          {roster_id, "roster@tryinstaclean.com", "Roster"},
          {email_id, "approved@tryinstaclean.com", "Email"}
        ] do
      Repo.query!(
        """
        INSERT INTO public.cleaner_application_drafts (
          id, user_id, email, payload, current_step, created_at, updated_at, last_saved_at
        ) VALUES (
          $1::uuid, $2::uuid, $3, jsonb_build_object('firstName', $4::text, 'lastName', 'Person'), 1, $5, $5, $5
        )
        """,
        [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(id), email, name, now]
      )
    end

    assert {:ok, page} = Direct.list_admin_cleaner_application_drafts(@admin)
    assert Enum.map(page["drafts"], & &1["name"]) == ["Open Person"]
    assert page["directoryTotal"] == 1
    assert page["total"] == 1
  end

  defp listed_application(id) do
    assert {:ok, %{"applications" => applications}} =
             Direct.list_admin_cleaner_applications(@admin)

    Enum.find(applications, &(&1["id"] == id))
  end

  defp insert_kyc_profile(user_id, level, status, answer, applicant_id) do
    Repo.query!(
      """
      INSERT INTO public.kyc_profiles (
        id, user_id, level_name, kyc_status, review_answer, sumsub_applicant_id,
        last_event_type, updated_at, created_at
      ) VALUES (
        $1::uuid, $2::uuid, $3, $4, $5, $6, 'applicantReviewed', now(), now()
      )
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(user_id),
        level,
        status,
        answer,
        applicant_id
      ]
    )
  end

  defp insert_application(id, user_id, attrs) do
    Repo.query!(
      """
      INSERT INTO public.cleaner_applications (
        id, user_id, name, phone, status, kyc_status, kyc_review_answer, kyc_review_status,
        sumsub_applicant_id, sumsub_level_name, hourly_rate, bio, years_of_experience,
        hours_per_week, has_cleaning_experience, previous_employers, client_description,
        additional_skills, available_days, availability, reference1_name, reference1_phone,
        reference1_relationship
      ) VALUES (
        $1::uuid, $2::uuid, 'Esther Osae', '233535707075', 'pending', $3, $4, $5,
        $6, $7, 50, 'Cleans homes', $8, $9, $10, $11, $12, $13, $14, $15::jsonb, $16, $17, $18
      )
      """,
      [
        Ecto.UUID.dump!(id),
        user_id && Ecto.UUID.dump!(user_id),
        attrs[:kyc_status] || "not_started",
        attrs[:kyc_review_answer],
        attrs[:kyc_review_status],
        attrs[:sumsub_applicant_id],
        attrs[:sumsub_level_name],
        attrs[:years],
        attrs[:hours],
        attrs[:experience],
        attrs[:employers],
        attrs[:client],
        attrs[:skills],
        attrs[:days],
        attrs[:availability],
        attrs[:reference1_name],
        attrs[:reference1_phone],
        attrs[:reference1_relationship]
      ]
    )
  end
end
