defmodule Mithril.DirectDispatchTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectDispatch
  alias Mithril.DirectDispatchRequestSafety
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
          "payment_attempts",
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
      service_id integer NOT NULL,
      address text NOT NULL,
      scheduled_date date NOT NULL,
      scheduled_time time NOT NULL,
      duration_hours numeric NOT NULL,
      timezone text,
      status text NOT NULL DEFAULT 'pending',
      payment_status text NOT NULL DEFAULT 'paid',
      reference text,
      promotion_id uuid,
      promotion_discount_minor bigint DEFAULT 0
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payment_attempts (
      id uuid PRIMARY KEY,
      booking_id uuid NOT NULL REFERENCES public.bookings(id),
      status text NOT NULL
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
      idempotency_key text,
      intent_fingerprint text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX direct_service_requests_customer_idempotency_uidx
      ON public.direct_service_requests (customer_id, idempotency_key)
      WHERE idempotency_key IS NOT NULL
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
    needed_by = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

    assert {:ok, created} =
             DirectDispatch.create_urgent_request(customer_id, %{
               "role" => "elder_caregiver",
               "priority" => "urgent",
               "neededBy" => needed_by,
               "durationHours" => 6,
               "householdAddress" => "East Legon Hills, Accra",
               "requirements" => %{},
               "notes" => "Non-medical companionship and mobility help"
             })

    assert created.kind == "urgent_help"
    assert created.status == "submitted"

    assert {:ok, [request]} = DirectDispatch.list_service_requests(customer_id)
    assert request["id"] == created.id
    assert request["role"] == "elder_caregiver"
    assert request["priority"] == "urgent"
    assert request["requirements"] == %{}
  end

  test "urgent help rejects unnamed requirement keys" do
    customer_id = insert_user!("requirements@example.com", "+233500000096")
    needed_by = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

    assert {:error, :invalid_request} =
             DirectDispatch.create_urgent_request(customer_id, %{
               "role" => "cleaner",
               "neededBy" => needed_by,
               "durationHours" => 2,
               "householdAddress" => "Labone, Accra",
               "requirements" => %{"mobilitySupport" => true}
             })
  end

  test "urgent-help retries with the same idempotency key return the original request" do
    customer_id = insert_user!("retry@example.com", "+233500000099")
    key = "urgent-0b76d53d-95d6-4b79"
    needed_by = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

    params = %{
      "role" => "cleaner",
      "priority" => "urgent",
      "neededBy" => needed_by,
      "durationHours" => 3,
      "householdAddress" => "East Legon, Accra",
      "requirements" => %{},
      "notes" => "Need help today",
      "idempotencyKey" => key
    }

    assert {:ok, first} = DirectDispatch.create_urgent_request(customer_id, params)
    assert {:ok, retry} = DirectDispatch.create_urgent_request(customer_id, params)
    assert retry.id == first.id

    [[count]] =
      Repo.query!(
        """
        SELECT count(*)::int
        FROM public.direct_service_requests
        WHERE customer_id = $1 AND idempotency_key = $2
        """,
        [Ecto.UUID.dump!(customer_id), key]
      ).rows

    assert count == 1
  end

  test "urgent-help replay succeeds after the original neededBy is already past" do
    customer_id = insert_user!("late-retry@example.com", "+233500000098")
    key = "urgent-6f65fa62-4d7c-4e21"
    needed_by = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.to_iso8601()

    params = %{
      "role" => "cleaner",
      "priority" => "urgent",
      "neededBy" => needed_by,
      "durationHours" => 2,
      "householdAddress" => "Cantonments, Accra",
      "requirements" => %{},
      "notes" => "Retry after a lost response",
      "idempotencyKey" => key
    }

    assert {:ok, fingerprint} = DirectDispatch.urgent_request_fingerprint_for_params(params)
    request_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.direct_service_requests (
        id, customer_id, kind, status, priority, role, requested_start_at,
        duration_hours, household_address_snapshot, requirements, notes,
        created_by_user_id, idempotency_key, intent_fingerprint
      ) VALUES (
        $1, $2, 'urgent_help', 'submitted', 'urgent', 'cleaner', $3, 2,
        'Cantonments, Accra', '{}'::jsonb,
        'Retry after a lost response', $2, $4, $5
      )
      """,
      [
        Ecto.UUID.dump!(request_id),
        Ecto.UUID.dump!(customer_id),
        DateTime.from_iso8601(needed_by) |> elem(1),
        key,
        fingerprint
      ]
    )

    assert {:ok, replay} = DirectDispatchRequestSafety.create_urgent_request(customer_id, params)
    assert replay.id == request_id
  end

  test "urgent-help idempotency keys cannot be reused for a different request" do
    customer_id = insert_user!("conflict@example.com", "+233500000097")
    key = "urgent-9e5dd90e-6baf-49aa"
    needed_by = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    original = %{
      "role" => "cleaner",
      "priority" => "urgent",
      "neededBy" => needed_by,
      "durationHours" => 2,
      "householdAddress" => "Labone, Accra",
      "requirements" => %{},
      "notes" => "Original intent",
      "idempotencyKey" => key
    }

    assert {:ok, _created} =
             DirectDispatchRequestSafety.create_urgent_request(customer_id, original)

    assert {:error, :idempotency_conflict} =
             DirectDispatchRequestSafety.create_urgent_request(
               customer_id,
               Map.put(original, "householdAddress", "Airport Residential, Accra")
             )
  end

  test "prevents duplicate active replacement requests for one booking" do
    customer_id = insert_user!("customer@example.com", "+233500000002")
    booking_id = Ecto.UUID.generate()
    scheduled_date = Date.utc_today() |> Date.add(1)

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, service_id, address, scheduled_date, scheduled_time,
        duration_hours, timezone, status
      ) VALUES ($1, $2, 1, 'Labone, Accra', $3, '10:00', 3, 'Africa/Accra', 'pending')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), scheduled_date]
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

  test "records a text booking id on the booking origin" do
    customer_id = insert_user!("origin-customer@tryinstaclean.com", "+233555000311")
    admin_id = insert_user!("origin-admin@tryinstaclean.com", "+233555000312")
    booking_id = Ecto.UUID.generate()
    {:ok, customer_uuid} = Ecto.UUID.dump(customer_id)
    {:ok, admin_uuid} = Ecto.UUID.dump(admin_id)

    assert {:ok, true} =
             DirectDispatch.insert_booking_origin(
               booking_id,
               customer_uuid,
               admin_uuid,
               "phone",
               "Booked from concierge"
             )

    assert %{rows: [[^booking_id]]} =
             Repo.query!("SELECT booking_id::text FROM public.direct_booking_origins")
  end

  test "reviewers can book for a customer the same way admins can" do
    reviewer_id = insert_user!("reviewer@tryinstaclean.com", "+233555000111")
    grant_role!(reviewer_id, "reviewer")

    assert {:error, :customer_not_found} =
             DirectDispatch.create_admin_booking(reviewer_id, %{
               "customerUserId" => Ecto.UUID.generate(),
               "source" => "phone",
               "consentConfirmed" => true,
               "scheduledDate" => "2026-10-01"
             })
  end

  test "customers cannot use the admin-assisted booking path" do
    customer_id = insert_user!("client@tryinstaclean.com", "+233555000222")

    assert {:error, :forbidden} =
             DirectDispatch.create_admin_booking(customer_id, %{
               "customerUserId" => customer_id,
               "source" => "phone",
               "consentConfirmed" => true,
               "scheduledDate" => "2026-10-01"
             })
  end

  test "custom-day and recurring schedules expand into visit dates" do
    assert {:ok, ["2026-10-01"]} =
             DirectDispatch.expand_booking_dates(%{"scheduledDate" => "2026-10-01"})

    assert {:ok, ["2026-10-01", "2026-10-08", "2026-10-15"]} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "recurring",
               "scheduledDate" => "2026-10-01",
               "recurrenceInterval" => "weekly",
               "occurrenceCount" => 3
             })

    assert {:ok, ["2026-01-31", "2026-02-28"]} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "recurring",
               "scheduledDate" => "2026-01-31",
               "recurrenceInterval" => "monthly",
               "occurrenceCount" => "2"
             })

    assert {:ok, ["2026-10-01", "2026-10-02", "2026-10-03"]} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "recurring",
               "scheduledDate" => "2026-10-01",
               "recurrenceInterval" => "daily",
               "occurrenceCount" => 3
             })

    assert {:ok, ["2026-01-31", "2026-04-30", "2026-07-31"]} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "recurring",
               "scheduledDate" => "2026-01-31",
               "recurrenceInterval" => "quarterly",
               "occurrenceCount" => 3
             })

    assert {:ok, ["2024-02-29", "2025-02-28"]} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "recurring",
               "scheduledDate" => "2024-02-29",
               "recurrenceInterval" => "annually",
               "occurrenceCount" => 2
             })

    assert {:ok, ["2026-10-02", "2026-10-09"]} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "custom_days",
               "customDates" => ["2026-10-09", "2026-10-02", "2026-10-02"]
             })

    assert {:error, :invalid_request} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "custom_days",
               "customDates" => []
             })

    assert {:error, :invalid_request} =
             DirectDispatch.expand_booking_dates(%{
               "scheduleKind" => "custom_days",
               "customDates" => ["not-a-date"]
             })
  end

  test "admin booking idempotency keys are stable and distinct per visit" do
    key = "9a52619b-e692-48f9-a901-ddf55d341d1d"

    first = DirectDispatch.admin_booking_idempotency_key(key, "2026-10-01", 0)
    retry = DirectDispatch.admin_booking_idempotency_key(key, "2026-10-01", 0)
    edited_same_visit = DirectDispatch.admin_booking_idempotency_key(key, "2026-11-01", 0)
    second = DirectDispatch.admin_booking_idempotency_key(key, "2026-10-08", 1)

    assert first == retry
    assert first == edited_same_visit
    refute first == second
    assert String.starts_with?(first, "admin:")
    assert String.length(first) <= 128
  end

  test "admin-assisted booking rejects malformed idempotency keys" do
    assert {:error, :invalid_request} =
             DirectDispatch.create_admin_booking(Ecto.UUID.generate(), %{
               "customerUserId" => Ecto.UUID.generate(),
               "source" => "phone",
               "consentConfirmed" => true,
               "idempotencyKey" => "short"
             })
  end

  test "invalid custom days are rejected before a booking is created" do
    admin_id = insert_user!("ops@tryinstaclean.com", "+233555000333")
    customer_id = insert_user!("booked@tryinstaclean.com", "+233555000444")
    grant_role!(admin_id, "admin")

    assert {:error, :invalid_request} =
             DirectDispatch.create_admin_booking(admin_id, %{
               "customerUserId" => customer_id,
               "source" => "whatsapp",
               "consentConfirmed" => true,
               "sendNotifications" => false,
               "scheduleKind" => "custom_days",
               "customDates" => []
             })
  end

  test "visit hours are calculated in the database from bedrooms and bathrooms" do
    Repo.query!("DROP TABLE IF EXISTS public.service_types CASCADE")

    Repo.query!("""
    CREATE TABLE public.service_types (
      id integer PRIMARY KEY,
      minimum_duration_hours numeric,
      maximum_duration_hours numeric,
      duration_increment_hours numeric
    )
    """)

    sql =
      File.read!(
        Path.expand("../../priv/repo/sql/direct/20261119143000_direct_visit_hours.sql", __DIR__)
      )

    Repo.query!(sql)

    Repo.query!("""
    INSERT INTO public.service_types (
      id, minimum_duration_hours, maximum_duration_hours, duration_increment_hours
    ) VALUES
      (1, 3, 10, 0.5),
      (2, 2, 5, 0.5),
      (3, 3.5, 10, 0.5),
      (4, 3.2, 10, 0.5),
      (5, 2, 3.25, 0.5),
      (6, 2, 10, 0.25)
    """)

    assert {:ok, %{durationHours: 3.5, homeSize: "2 bed, 3 bath"}} =
             DirectDispatch.visit_hours(2, 3)

    assert {:ok, %{durationHours: 8.5, homeSize: "10 bed, 10 bath"}} =
             DirectDispatch.visit_hours(10, 10)

    assert {:ok, %{durationHours: 3.0, homeSize: "1 bed, 1 bath"}} =
             DirectDispatch.visit_hours(1, 1, 1)

    assert {:ok, %{durationHours: 5.0, homeSize: "10 bed, 10 bath"}} =
             DirectDispatch.visit_hours(10, 10, 2)

    assert {:ok, %{durationHours: 8.5, homeSize: "10 bed, 10 bath"}} =
             DirectDispatch.visit_hours(10, 10, 3)

    assert {:ok, %{durationHours: 4.5, homeSize: "1 bed, 10 bath"}} =
             DirectDispatch.visit_hours(0, 99)

    assert {:ok, %{durationHours: 3.2, homeSize: "1 bed, 1 bath"}} =
             DirectDispatch.visit_hours(1, 1, 4)

    assert {:ok, %{durationHours: 3.25, homeSize: "10 bed, 10 bath"}} =
             DirectDispatch.visit_hours(10, 10, 5)

    assert {:ok, %{durationHours: 3.5, homeSize: "2 bed, 3 bath"}} =
             DirectDispatch.visit_hours(2, 3, 6)
  end

  test "rejects an extra-task id that is not a catalog key" do
    assert {:error, :invalid_request} =
             DirectDispatch.create_admin_booking(Ecto.UUID.generate(), %{
               "customerUserId" => Ecto.UUID.generate(),
               "source" => "phone",
               "consentConfirmed" => true,
               "extraTaskIds" => ["windows", "not an id"]
             })
  end

  test "sums hours for known extra tasks and rejects an unknown id" do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.extra_tasks (
      id text PRIMARY KEY,
      label text NOT NULL,
      hours numeric NOT NULL
    )
    """)

    Repo.query!("""
    INSERT INTO public.extra_tasks (id, label, hours)
    VALUES ('inside-windows', 'Inside windows', 0.5), ('oven', 'Oven', 1)
    ON CONFLICT (id) DO UPDATE SET hours = EXCLUDED.hours, label = EXCLUDED.label
    """)

    assert {:ok, extra} = DirectDispatch.extra_task_hours(["inside-windows", "oven"])
    assert Decimal.equal?(extra, Decimal.new("1.5"))
    assert {:error, :unknown_extra_task} = DirectDispatch.extra_task_hours(["missing-task"])
  end

  test "an unpaid open booking can take one promotion" do
    open = %{
      payment_status: "pending",
      status: "confirmed",
      promotion_id: nil,
      promotion_discount_minor: 0,
      checkout_open: false
    }

    assert :ok == DirectDispatch.promotion_apply_gate(open)

    assert {:error, :booking_paid} ==
             DirectDispatch.promotion_apply_gate(%{open | payment_status: "paid"})

    assert {:error, :promotion_closed} ==
             DirectDispatch.promotion_apply_gate(%{open | status: "completed"})

    assert {:error, :promotion_already_applied} ==
             DirectDispatch.promotion_apply_gate(%{open | promotion_id: Ecto.UUID.generate()})

    assert {:error, :promotion_already_applied} ==
             DirectDispatch.promotion_apply_gate(%{open | promotion_discount_minor: 10_000})

    assert {:error, :checkout_already_initialized} ==
             DirectDispatch.promotion_apply_gate(%{open | checkout_open: true})
  end

  test "promotion repricing refuses an initialized payment attempt even with no booking reference" do
    customer_id = insert_user!("promotion-checkout@example.com", "+233500000088")
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, service_id, address, scheduled_date, scheduled_time,
        duration_hours, status, payment_status
      ) VALUES ($1, $2, 1, 'Accra', CURRENT_DATE + 2, '10:00', 2, 'confirmed', 'pending')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id)]
    )

    Repo.query!(
      "INSERT INTO public.payment_attempts (id, booking_id, status) VALUES ($1, $2, 'ready')",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(booking_id)]
    )

    assert {:error, :checkout_already_initialized} ==
             DirectDispatch.apply_booking_promotion(booking_id, %{"promotionSlug" => "welcome"})

    [[payment_status, promotion_id]] =
      Repo.query!(
        "SELECT payment_status, promotion_id FROM public.bookings WHERE id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert payment_status == "pending"
    assert promotion_id == nil
  end

  test "promotion repricing refuses a retained booking payment reference" do
    customer_id = insert_user!("promotion-reference@example.com", "+233500000087")
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, service_id, address, scheduled_date, scheduled_time,
        duration_hours, status, payment_status, reference
      ) VALUES ($1, $2, 1, 'Accra', CURRENT_DATE + 2, '10:00', 2, 'confirmed', 'pending', 'old-checkout')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id)]
    )

    assert {:error, :checkout_already_initialized} ==
             DirectDispatch.apply_booking_promotion(booking_id, %{"promotionSlug" => "welcome"})
  end

  test "a first-time offer covers two hours of the visit" do
    discount =
      DirectDispatch.promotion_discount_minor(
        %{type: "free_hours", value: Decimal.new("2"), max_duration_hours: Decimal.new("2")},
        %{
          duration_hours: Decimal.new("2.5"),
          extra_task_hours: Decimal.new("0"),
          work_rate: Decimal.new("50"),
          labor_minor: 12_500,
          final_amount_minor: 16_475
        }
      )

    assert discount == 10_000
  end

  test "a percent promotion is taken from the visit total" do
    discount =
      DirectDispatch.promotion_discount_minor(
        %{type: "percent_off", value: Decimal.new("25"), max_duration_hours: nil},
        %{
          duration_hours: Decimal.new("2.5"),
          extra_task_hours: Decimal.new("0"),
          work_rate: Decimal.new("50"),
          labor_minor: 12_500,
          final_amount_minor: 16_475
        }
      )

    assert discount == 4_119
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

  defp grant_role!(user_id, role) do
    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, $2)", [
      Ecto.UUID.dump!(user_id),
      role
    ])
  end
end
