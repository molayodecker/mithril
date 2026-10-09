defmodule Mithril.DirectAdminOpsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminPayouts
  alias Mithril.DirectAdminReviews
  alias Mithril.DirectAdminTeam
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate ops fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "cleaner_payouts",
          "payout_methods",
          "wallets",
          "reviews",
          "bookings",
          "service_types",
          "user_roles",
          "users",
          "profiles",
          "cleaner_data"
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
      status text NOT NULL DEFAULT 'active'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.wallets (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      balance_subunit integer NOT NULL DEFAULT 0
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_payouts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      recipient_code text NOT NULL DEFAULT 'RCP',
      amount bigint NOT NULL,
      currency text NOT NULL DEFAULT 'GHS',
      reference text NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      error_message text,
      created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payout_methods (
      user_id uuid NOT NULL,
      bank_name text,
      masked_account text,
      account_name text,
      is_primary boolean DEFAULT true,
      is_default boolean DEFAULT false,
      updated_at timestamptz DEFAULT timezone('utc', now())
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_types (id serial PRIMARY KEY, name text NOT NULL)
    """)

    Repo.query!("INSERT INTO public.service_types (id, name) VALUES (1, 'Regular clean')")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      service_id integer NOT NULL,
      status text NOT NULL DEFAULT 'completed',
      scheduled_date date NOT NULL DEFAULT current_date
    )
    """)

    Repo.query!("""
    CREATE TABLE public.reviews (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid REFERENCES public.bookings(id),
      reviewer_id uuid NOT NULL,
      reviewee_id uuid NOT NULL,
      rating integer NOT NULL,
      comment text,
      response text,
      status text DEFAULT 'published',
      created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
    )
    """)

    cleaner_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    admin_id = insert_user!("ops@tryinstaclean.com", "Ops Lead")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(cleaner_id),
      "cleaner@example.com",
      "+233500000001"
    ])

    Repo.query!("INSERT INTO public.profiles (id, fullname) VALUES ($1, $2)", [
      Ecto.UUID.dump!(cleaner_id),
      "Akosua Boateng"
    ])

    Repo.query!("INSERT INTO public.cleaner_data (user_id) VALUES ($1)", [
      Ecto.UUID.dump!(cleaner_id)
    ])

    Repo.query!("INSERT INTO public.wallets (user_id, balance_subunit) VALUES ($1, 291600)", [
      Ecto.UUID.dump!(cleaner_id)
    ])

    Repo.query!(
      """
      INSERT INTO public.cleaner_payouts (user_id, amount, reference, status)
      VALUES ($1, 291600, 'payout-1', 'pending')
      """,
      [Ecto.UUID.dump!(cleaner_id)]
    )

    Repo.query!(
      "INSERT INTO public.payout_methods (user_id, bank_name, masked_account) VALUES ($1, 'MTN MoMo', '•••• 1234')",
      [
        Ecto.UUID.dump!(cleaner_id)
      ]
    )

    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (id, customer_id, cleaner_id, service_id)
      VALUES ($1, $2, $3, 1)
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), Ecto.UUID.dump!(cleaner_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.reviews (booking_id, reviewer_id, reviewee_id, rating, comment)
      VALUES ($1, $2, $3, 5, 'Great clean')
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(customer_id),
        Ecto.UUID.dump!(cleaner_id)
      ]
    )

    {:ok, admin_id: admin_id}
  end

  test "lists payouts summary and rows", %{admin_id: admin_id} do
    assert {:ok, %{summary: summary, payouts: payouts}} = DirectAdminPayouts.list(admin_id)
    assert summary["owedMinor"] == 291_600
    assert length(payouts) == 1
    assert hd(payouts)["cleanerName"] == "Akosua Boateng"
  end

  test "lists reviews", %{admin_id: admin_id} do
    assert {:ok, %{stats: stats, reviews: reviews}} = DirectAdminReviews.list(admin_id)
    assert stats["thisMonthCount"] == 1
    assert hd(reviews)["rating"] == 5
  end

  test "lists team for admin", %{admin_id: admin_id} do
    assert {:ok, %{members: members}} = DirectAdminTeam.list(admin_id)
    assert length(members) == 1
    assert hd(members)["name"] == "Ops Lead"
  end

  test "forbids reviewers from the team roster and guests from payouts" do
    reviewer_id = insert_user!("reviewer@tryinstaclean.com", "Reviewer")
    guest_id = insert_user!("guest@example.com", "Guest")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'reviewer')", [
      Ecto.UUID.dump!(reviewer_id)
    ])

    assert {:error, :forbidden} = DirectAdminTeam.list(reviewer_id)
    assert {:error, :forbidden} = DirectAdminPayouts.list(guest_id)
    assert {:error, :forbidden} = DirectAdminReviews.list(guest_id)
  end

  defp insert_user!(email, fullname) do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(id),
      email,
      "+233500000099"
    ])

    Repo.query!("INSERT INTO public.profiles (id, fullname) VALUES ($1, $2)", [
      Ecto.UUID.dump!(id),
      fullname
    ])

    id
  end
end
