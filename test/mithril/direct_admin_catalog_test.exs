defmodule Mithril.DirectAdminCatalogTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminPromotions
  alias Mithril.DirectAdminReports
  alias Mithril.DirectAdminServiceAreas
  alias Mithril.DirectAdminServices
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate catalog fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("CREATE EXTENSION IF NOT EXISTS citext")

    for table <- [
          "promotion_redemptions",
          "promotion_codes",
          "promotions",
          "bookings",
          "service_areas",
          "cleaner_data",
          "service_types",
          "service_categories",
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
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_categories (
      id serial PRIMARY KEY,
      name text NOT NULL,
      slug text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_types (
      id serial PRIMARY KEY,
      category_id integer REFERENCES public.service_categories(id),
      name text NOT NULL,
      price numeric NOT NULL DEFAULT 80,
      duration text NOT NULL DEFAULT '2 hours',
      category text NOT NULL DEFAULT 'cleaning',
      active boolean NOT NULL DEFAULT true,
      description text,
      minimum_duration_hours numeric DEFAULT 2,
      maximum_duration_hours numeric DEFAULT 12,
      duration_increment_hours numeric DEFAULT 0.5,
      specialty_slug text,
      weight integer DEFAULT 0,
      features text[] DEFAULT '{}',
      last_updated timestamptz DEFAULT timezone('utc', now())
    )
    """)

    Repo.query!(
      "INSERT INTO public.service_categories (id, name, slug) VALUES (1, 'Cleaning', 'cleaning')"
    )

    Repo.query!(
      "INSERT INTO public.service_types (id, category_id, name, price, specialty_slug, active) VALUES (1, 1, 'Regular clean', 90, 'regular_cleaning', true)"
    )

    Repo.query!("""
    CREATE TABLE public.service_areas (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL,
      country text NOT NULL DEFAULT 'GH',
      active boolean NOT NULL DEFAULT true,
      created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
    )
    """)

    Repo.query!(
      "INSERT INTO public.service_areas (id, name, active) VALUES ('550e8400-e29b-41d4-a716-446655440001', 'East Legon', true)"
    )

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY,
      status text NOT NULL DEFAULT 'active',
      service_areas text[]
    )
    """)

    cleaner_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO public.cleaner_data (user_id, status, service_areas) VALUES ($1, 'active', ARRAY['East Legon']::text[])",
      [Ecto.UUID.dump!(cleaner_id)]
    )

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      service_id integer NOT NULL,
      status text NOT NULL DEFAULT 'confirmed',
      payment_status text NOT NULL DEFAULT 'paid',
      scheduled_date date NOT NULL,
      scheduled_time time,
      address text,
      final_amount_minor bigint,
      total_price numeric
    )
    """)

    Repo.query!("""
    CREATE TABLE public.booking_refunds (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id),
      refund_amount_minor bigint NOT NULL,
      status text NOT NULL DEFAULT 'processed'
    )
    """)

    customer_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (
        customer_id, cleaner_id, service_id, status, payment_status, scheduled_date, address, final_amount_minor
      ) VALUES ($1, $2, 1, 'confirmed', 'paid', current_date, 'East Legon, Accra', 25000)
      """,
      [Ecto.UUID.dump!(customer_id), Ecto.UUID.dump!(cleaner_id)]
    )

    Repo.query!("""
    CREATE TABLE public.promotions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      slug text NOT NULL UNIQUE,
      type text NOT NULL,
      value integer NOT NULL,
      headline text NOT NULL,
      active boolean NOT NULL DEFAULT true,
      valid_from timestamptz,
      valid_to timestamptz,
      max_redemptions integer,
      terms_markdown text
    )
    """)

    promo_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.promotions (id, slug, type, value, headline, active)
      VALUES ($1, 'welcome', 'percent_off', 10, '10% off first booking', true)
      """,
      [Ecto.UUID.dump!(promo_id)]
    )

    Repo.query!("""
    CREATE TABLE public.promotion_codes (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      promotion_id uuid NOT NULL REFERENCES public.promotions(id) ON DELETE CASCADE,
      code citext NOT NULL UNIQUE,
      active boolean NOT NULL DEFAULT true,
      max_redemptions integer,
      created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
    )
    """)

    Repo.query!(
      "INSERT INTO public.promotion_codes (promotion_id, code) VALUES ($1, 'AKWABA10')",
      [Ecto.UUID.dump!(promo_id)]
    )

    Repo.query!("""
    CREATE TABLE public.promotion_redemptions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      promotion_id uuid NOT NULL REFERENCES public.promotions(id) ON DELETE CASCADE,
      status text NOT NULL DEFAULT 'redeemed'
    )
    """)

    Repo.query!(
      "INSERT INTO public.promotion_redemptions (user_id, promotion_id, status) VALUES ($1, $2, 'redeemed')",
      [Ecto.UUID.dump!(customer_id), Ecto.UUID.dump!(promo_id)]
    )

    :ok
  end

  test "lists and updates services for staff admin" do
    admin_id = insert_admin!()

    assert {:ok, services} = DirectAdminServices.list(admin_id)
    assert length(services) == 1
    assert hd(services)["name"] == "Regular clean"

    assert {:ok, service} =
             DirectAdminServices.update(admin_id, "1", %{
               "priceGhs" => "95",
               "active" => false
             })

    assert Decimal.equal?(Decimal.new(to_string(service["priceGhs"])), Decimal.new("95"))
    assert service["active"] == false
  end

  test "lists promotion codes and service areas" do
    staff_id = insert_reviewer!()

    assert {:ok, codes} = DirectAdminPromotions.list_codes(staff_id)
    assert hd(codes)["code"] == "AKWABA10"
    assert hd(codes)["redemptionCount"] == 1

    assert {:ok, areas} = DirectAdminServiceAreas.list(staff_id)
    assert hd(areas)["name"] == "East Legon"
    assert hd(areas)["cleanerCount"] == 1
  end

  test "builds reports summary" do
    staff_id = insert_reviewer!()

    assert {:ok, summary} = DirectAdminReports.summary(staff_id, %{"days" => 7})
    assert summary["bookingsCount"] == 1
    assert summary["revenueMinor"] == 25_000
    assert summary["fillRatePercent"] == 100.0
  end

  test "forbids non-staff" do
    guest_id = insert_user!("guest@example.com")

    assert {:error, :forbidden} = DirectAdminServices.list(guest_id)
    assert {:error, :forbidden} = DirectAdminPromotions.list_codes(guest_id)
  end

  test "reviewers can list services but cannot update pricing" do
    reviewer_id = insert_reviewer!()

    assert {:ok, services} = DirectAdminServices.list(reviewer_id)
    assert length(services) == 1

    assert {:error, :forbidden} =
             DirectAdminServices.update(reviewer_id, "1", %{"priceGhs" => "95"})
  end

  defp insert_admin! do
    admin_id = insert_user!("ops@tryinstaclean.com")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    admin_id
  end

  defp insert_reviewer! do
    reviewer_id = insert_user!("reviewer@tryinstaclean.com")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'reviewer')", [
      Ecto.UUID.dump!(reviewer_id)
    ])

    reviewer_id
  end

  defp insert_user!(email) do
    id = Ecto.UUID.generate()
    uid = Ecto.UUID.dump!(id)

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      uid,
      email,
      "+233500000000"
    ])

    id
  end
end
