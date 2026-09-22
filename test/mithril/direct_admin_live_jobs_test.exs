defmodule Mithril.DirectAdminLiveJobsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminLiveJobs
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate live job fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "booking_job_photos",
          "cleaner_tracking",
          "booking_timeline",
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
      address text,
      location_coordinates jsonb,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.booking_timeline (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid REFERENCES public.bookings(id) ON DELETE CASCADE,
      stage text NOT NULL,
      notes text,
      changed_at timestamptz DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_tracking (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
      cleaner_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
      latitude double precision NOT NULL,
      longitude double precision NOT NULL,
      accuracy double precision,
      heading double precision,
      created_at timestamptz DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.booking_job_photos (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
      photo_type text NOT NULL,
      storage_path text NOT NULL,
      uploaded_by uuid NOT NULL,
      caption text,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!(
      "INSERT INTO public.service_types (id, name, specialty_slug) VALUES (1, 'Deep Cleaning', 'cleaning')"
    )

    :ok
  end

  test "rejects non-staff users" do
    guest_id = insert_user!("guest@example.com", "+233500000010")
    assert {:error, :forbidden} = DirectAdminLiveJobs.list(guest_id)
  end

  test "lists on-job and today's assigned bookings with progress" do
    admin_id = insert_admin!()
    customer_id = insert_user!("customer@example.com", "+233500000001", "Ama Mensah")
    cleaner_id = insert_user!("cleaner@example.com", "+233500000002", "Kojo Boateng")
    idle_cleaner_id = insert_user!("idle@example.com", "+233500000003", "Idle Helper")

    live_id =
      insert_booking!(customer_id, cleaner_id, "in_progress", %{
        address: "12 Independence Ave, Accra",
        location: %{"latitude" => 5.56, "longitude" => -0.2}
      })

    today_id = insert_booking!(customer_id, cleaner_id, "scheduled")
    _completed = insert_booking!(customer_id, cleaner_id, "completed")
    _unassigned = insert_booking!(customer_id, nil, "en_route")
    _idle = insert_booking!(customer_id, idle_cleaner_id, "scheduled", %{days_offset: 3})

    changed_at = ~U[2026-09-22 08:15:00Z]

    Repo.query!(
      """
      INSERT INTO public.booking_timeline (booking_id, stage, changed_at)
      VALUES ($1, 'scheduled', $2), ($1, 'en_route', $3), ($1, 'arrived', $4), ($1, 'in_progress', $5)
      """,
      [
        Ecto.UUID.dump!(live_id),
        changed_at,
        DateTime.add(changed_at, 20 * 60, :second),
        DateTime.add(changed_at, 40 * 60, :second),
        DateTime.add(changed_at, 50 * 60, :second)
      ]
    )

    Repo.query!(
      """
      INSERT INTO public.cleaner_tracking (booking_id, cleaner_id, latitude, longitude, heading, accuracy, created_at)
      VALUES ($1, $2, 5.561, -0.198, 92, 8, $3), ($1, $2, 5.562, -0.197, 88, 6, $4)
      """,
      [
        Ecto.UUID.dump!(live_id),
        Ecto.UUID.dump!(cleaner_id),
        DateTime.add(changed_at, 30 * 60, :second),
        DateTime.add(changed_at, 55 * 60, :second)
      ]
    )

    Repo.query!(
      """
      INSERT INTO public.booking_job_photos (booking_id, photo_type, storage_path, uploaded_by)
      VALUES ($1, 'before', 'jobs/before-1.jpg', $2), ($1, 'before', 'jobs/before-2.jpg', $2), ($1, 'during', 'jobs/during-1.jpg', $2)
      """,
      [Ecto.UUID.dump!(live_id), Ecto.UUID.dump!(cleaner_id)]
    )

    assert {:ok, payload} = DirectAdminLiveJobs.list(admin_id)
    assert is_binary(payload["generatedAt"])
    ids = Enum.map(payload["jobs"], & &1["bookingId"])
    assert live_id in ids
    assert today_id in ids
    assert length(payload["jobs"]) == 2

    live = Enum.find(payload["jobs"], &(&1["bookingId"] == live_id))
    assert live["status"] == "in_progress"
    assert live["cleanerName"] == "Kojo Boateng"
    assert live["customerName"] == "Ama Mensah"
    assert live["latitude"] == 5.56
    assert live["longitude"] == -0.2
    assert Enum.map(live["milestones"], & &1["stage"]) == [
             "scheduled",
             "en_route",
             "arrived",
             "in_progress"
           ]
    assert live["tracking"]["latitude"] == 5.562
    assert live["tracking"]["longitude"] == -0.197
    assert live["photos"] == %{
             "before" => 2,
             "during" => 1,
             "after" => 0,
             "issue" => 0,
             "total" => 3
           }
  end

  test "malformed coordinates on one booking do not erase valid coordinates on other jobs" do
    admin_id = insert_admin!()
    customer_id =
      insert_user!("coords-customer@example.com", "+233500000020", "Coordinates Customer")

    cleaner_id =
      insert_user!("coords-cleaner@example.com", "+233500000021", "Coordinates Cleaner")

    valid_id =
      insert_booking!(customer_id, cleaner_id, "in_progress", %{
        location: %{"latitude" => 5.6037, "longitude" => -0.187}
      })

    malformed_id =
      insert_booking!(customer_id, cleaner_id, "en_route", %{
        location: %{"latitude" => "not-a-number", "longitude" => "also-bad"}
      })

    assert {:ok, payload} = DirectAdminLiveJobs.list(admin_id)

    valid = Enum.find(payload["jobs"], &(&1["bookingId"] == valid_id))
    malformed = Enum.find(payload["jobs"], &(&1["bookingId"] == malformed_id))

    assert valid["latitude"] == 5.6037
    assert valid["longitude"] == -0.187
    assert malformed["latitude"] == nil
    assert malformed["longitude"] == nil
  end

  test "still lists jobs when progress tables are missing" do
    admin_id = insert_admin!()
    customer_id = insert_user!("customer@example.com", "+233500000004", "Yaw")
    cleaner_id = insert_user!("cleaner@example.com", "+233500000005", "Efua")
    booking_id = insert_booking!(customer_id, cleaner_id, "en_route")

    for table <- ["booking_job_photos", "cleaner_tracking", "booking_timeline"] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    assert {:ok, payload} = DirectAdminLiveJobs.list(admin_id)
    assert [job] = payload["jobs"]
    assert job["bookingId"] == booking_id
    assert job["milestones"] == []
    assert job["tracking"] == nil
    assert job["photos"]["total"] == 0
  end

  defp insert_admin! do
    admin_id = insert_user!("ops@tryinstaclean.com", "+233500000099")

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

  defp insert_booking!(customer_id, cleaner_id, status, opts \\ %{}) do
    id = Ecto.UUID.generate()
    days_offset = Map.get(opts, :days_offset, 0)
    address = Map.get(opts, :address, "East Legon")
    location = Map.get(opts, :location)

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, cleaner_id, service_id, status, scheduled_date, scheduled_time,
        duration_hours, timezone, address, location_coordinates
      )
      VALUES (
        $1, $2, $3, 1, $4,
        (timezone('Africa/Accra', now()))::date + $5::integer,
        '09:00', 3, 'Africa/Accra', $6, $7
      )
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(customer_id),
        if(cleaner_id, do: Ecto.UUID.dump!(cleaner_id), else: nil),
        status,
        days_offset,
        address,
        if(location, do: location, else: nil)
      ]
    )

    id
  end
end
