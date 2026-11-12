defmodule Mithril.AccountCompletionBonusTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.AccountCompletionBonus
  alias Mithril.MobileFunctions.PaystackPayout
  alias Mithril.Repo
  alias Mithril.WhatsApp.AccountCompletionTemplate

  @open "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
  @approved "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
  @roster "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
  @offered "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4"
  @email "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5"
  @admin "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1"

  setup do
    :ok = Sandbox.checkout(Repo)
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate bonus fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "account_completion_offers",
          "cleaner_application_drafts",
          "cleaner_applications",
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
    CREATE TABLE public.cleaner_applications (
      id uuid PRIMARY KEY,
      user_id uuid,
      name text,
      email text,
      phone text,
      status text,
      hourly_rate numeric
    )
    """)

    Repo.query!("CREATE TABLE public.cleaner_data (user_id uuid PRIMARY KEY)")

    Repo.query!("""
    CREATE TABLE public.cleaner_application_drafts (
      id uuid PRIMARY KEY,
      user_id uuid,
      email text,
      payload jsonb,
      created_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.account_completion_offers (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      draft_id uuid,
      user_id uuid,
      phone text NOT NULL,
      offered_at timestamptz NOT NULL DEFAULT now(),
      offered_by uuid NOT NULL,
      credited_at timestamptz,
      wallet_credit_id uuid
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX account_completion_offers_phone_key ON public.account_completion_offers (phone)"
    )

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.account_completion_phone(text)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    AS $function$
      SELECT CASE
        WHEN digits ~ '^\\+[1-9][0-9]{7,14}$' THEN digits
        WHEN digits ~ '^0[0-9]{9}$' THEN '+233' || substring(digits from 2)
        WHEN digits ~ '^233[0-9]{9}$' THEN '+' || digits
        ELSE NULL
      END
      FROM (
        SELECT regexp_replace(COALESCE(btrim($1), ''), '[[:space:]().-]', '', 'g') AS digits
      ) cleaned;
    $function$
    """)

    :ok
  end

  test "the WhatsApp says we will add GHS 25" do
    assert AccountCompletionTemplate.readable("Ama\n{Owusu}") =~
             "Hello Ama Owusu, finish your Instaclean account and we will add GHS 25"
  end

  test "a credited offer lowers the withdrawal minimum to GHS 25" do
    assert PaystackPayout.minimum_withdrawal_subunit(true) == 2_500
    assert PaystackPayout.minimum_withdrawal_subunit(false) == 5_000

    Repo.query!(
      "INSERT INTO public.users (id, phone) VALUES ($1, $2), ($3, $4)",
      [dump(@open), "0241111111", dump(@approved), "0242222222"]
    )

    Repo.query!(
      """
      INSERT INTO public.account_completion_offers (user_id, phone, offered_by, credited_at)
      VALUES ($1, $2, $3, now())
      """,
      [dump(@open), "+233241111111", dump(@admin)]
    )

    assert {:error, {:status, 400, %{ok: false, error: "Minimum withdrawal is GHS 50.00"}}} =
             PaystackPayout.initiate_transfer(@approved, %{
               "amount" => 2_500,
               "recipient" => "RCP_test123"
             })

    assert {:error, {:status, _, %{ok: false, error: error}}} =
             PaystackPayout.initiate_transfer(@open, %{
               "amount" => 2_500,
               "recipient" => "RCP_test123"
             })

    refute error == "Minimum withdrawal is GHS 50.00"
  end

  test "only an open draft with a phone is offered" do
    now = DateTime.utc_now()

    Repo.query!(
      "INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3), ($4, $5, $6), ($7, $8, $9), ($10, $11, $12), ($13, $14, $15)",
      [
        dump(@open),
        "open@tryinstaclean.com",
        "0241111111",
        dump(@approved),
        "approved@tryinstaclean.com",
        "0242222222",
        dump(@roster),
        "roster@tryinstaclean.com",
        "0243333333",
        dump(@offered),
        "offered@tryinstaclean.com",
        "0244444444",
        dump(@email),
        "email@tryinstaclean.com",
        "0245555555"
      ]
    )

    Repo.query!(
      "INSERT INTO public.profiles (id, fullname) VALUES ($1, $2), ($3, $4)",
      [dump(@open), "Open Person", dump(@approved), "Approved Person"]
    )

    Repo.query!(
      "INSERT INTO public.cleaner_applications (id, user_id, name, email, status, hourly_rate) VALUES ($1, $2, $3, $4, 'approved', 10)",
      [Ecto.UUID.bingenerate(), dump(@approved), "Approved Person", "approved@tryinstaclean.com"]
    )

    Repo.query!(
      "INSERT INTO public.cleaner_applications (id, user_id, name, email, status, hourly_rate) VALUES ($1, $2, $3, $4, 'approved', 10)",
      [
        Ecto.UUID.bingenerate(),
        Ecto.UUID.bingenerate(),
        "Email Person",
        "email@tryinstaclean.com"
      ]
    )

    Repo.query!("INSERT INTO public.cleaner_data (user_id) VALUES ($1)", [dump(@roster)])

    Repo.query!(
      """
      INSERT INTO public.account_completion_offers (user_id, phone, offered_by)
      VALUES ($1, $2, $3)
      """,
      [dump(@offered), "+233244444444", dump(@admin)]
    )

    for {id, name, at} <- [
          {@open, "Open", now},
          {@approved, "Approved", DateTime.add(now, 1, :second)},
          {@roster, "Roster", DateTime.add(now, 2, :second)},
          {@offered, "Offered", DateTime.add(now, 3, :second)},
          {@email, "Email", DateTime.add(now, 4, :second)}
        ] do
      Repo.query!(
        """
        INSERT INTO public.cleaner_application_drafts (id, user_id, email, payload, created_at)
        VALUES ($1, $2, $3, jsonb_build_object('firstName', $4::text, 'lastName', 'Person'), $5)
        """,
        [dump(id), dump(id), "#{String.downcase(name)}@tryinstaclean.com", name, at]
      )
    end

    assert {:ok, [%{name: "Open Person", phone: "+233241111111"}]} =
             AccountCompletionBonus.unoffered_drafts(20)
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
end
