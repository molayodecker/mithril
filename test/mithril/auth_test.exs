defmodule Mithril.AuthTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Auth
  alias Mithril.Auth.Token
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate auth fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "mithril_refresh_tokens",
          "mithril_auth_otps",
          "mithril_auth_identities",
          "mithril_auth_accounts",
          "payout_methods",
          "cleaner_data",
          "user_roles",
          "roles",
          "profiles",
          "users"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("DROP SCHEMA IF EXISTS auth CASCADE")
    Repo.query!("CREATE SCHEMA auth")

    Repo.query!("""
    CREATE TABLE auth.users (
      id uuid PRIMARY KEY,
      email text UNIQUE,
      phone text,
      encrypted_password text,
      created_at timestamptz,
      updated_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY REFERENCES auth.users(id),
      email text UNIQUE,
      phone text UNIQUE,
      password_hash text NOT NULL,
      status text DEFAULT 'active',
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY REFERENCES public.users(id),
      user_id uuid REFERENCES public.users(id),
      firstname text,
      lastname text,
      fullname text,
      avatar_url text,
      address text,
      location_wkt text
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.st_geogfromtext(wkt text)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    AS $$
      SELECT wkt
    $$
    """)

    Repo.query!("""
    CREATE TABLE public.roles (
      id text PRIMARY KEY,
      description text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL REFERENCES public.users(id),
      role_id text NOT NULL REFERENCES public.roles(id),
      PRIMARY KEY (user_id, role_id)
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY REFERENCES public.users(id),
      verified boolean NOT NULL DEFAULT false,
      status text NOT NULL DEFAULT 'pending',
      specialties text[] DEFAULT '{}',
      service_categories text[] DEFAULT '{}',
      hourly_rate numeric,
      rate_set_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payout_methods (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES public.users(id),
      purpose text NOT NULL DEFAULT 'payout',
      type text,
      recipient_code text
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.test_sync_auth_user()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      INSERT INTO public.users (id, email, password_hash, status)
      VALUES (NEW.id, NEW.email, '', 'active')
      ON CONFLICT (id) DO NOTHING;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER test_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.test_sync_auth_user()
    """)

    Repo.query!("""
    CREATE TABLE public.mithril_auth_accounts (
      user_id uuid PRIMARY KEY REFERENCES public.users(id),
      email text UNIQUE,
      phone text UNIQUE,
      password_hash text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.mithril_refresh_tokens (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES public.users(id),
      token_hash text NOT NULL UNIQUE,
      expires_at timestamptz NOT NULL,
      revoked_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.mithril_auth_identities (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES public.users(id),
      provider text NOT NULL,
      provider_subject text NOT NULL,
      email text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (provider, provider_subject)
    )
    """)

    Repo.query!("""
    CREATE TABLE public.mithril_auth_otps (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      phone text NOT NULL,
      code_hash text NOT NULL,
      expires_at timestamptz NOT NULL,
      attempt_count integer NOT NULL DEFAULT 0,
      consumed_at timestamptz,
      request_ip text,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    previous_http = Application.get_env(:mithril, :auth_http)

    Application.put_env(:mithril, :auth_http, &oauth_http/1)

    on_exit(fn ->
      if previous_http do
        Application.put_env(:mithril, :auth_http, previous_http)
      else
        Application.delete_env(:mithril, :auth_http)
      end
    end)

    :ok
  end

  test "login issues a JWT for an existing password" do
    {user_id, email} = insert_account("login@example.com", "correct-horse")

    assert {:ok, session} = Auth.login(email, "correct-horse")
    assert session.user.id == user_id
    assert session.user.email == email
    assert session.token_type == "bearer"

    assert {:ok, %{"sub" => ^user_id, "email" => ^email}} =
             Token.verify_access(session.access_token)
  end

  test "login accepts the user's phone even when the account also has an email" do
    {_user_id, _email} =
      insert_account("phone-login@example.com", "correct-horse", phone: "+233555000111")

    assert {:ok, session} = Auth.login("+233555000111", "correct-horse")
    assert session.user.email == "phone-login@example.com"
    assert session.user.phone == "+233555000111"
  end

  test "login accepts a Ghana local phone number" do
    {user_id, _email} =
      insert_account("ghana@example.com", "correct-horse", phone: "+233244123456")

    assert {:ok, session} = Auth.login("0244123456", "correct-horse")
    assert session.user.id == user_id
    assert session.user.phone == "+233244123456"
  end

  test "provision_admin creates a password login with the admin role" do
    assert {:ok, user} = Auth.provision_admin("ops@tryinstaclean.com", "correct-horse")
    assert user.email == "ops@tryinstaclean.com"
    assert user.admin
    assert Auth.admin?(user.id)

    assert {:ok, session} = Auth.login("ops@tryinstaclean.com", "correct-horse")
    assert session.user.id == user.id
    assert {:ok, me} = Auth.me(user.id)
    assert me.admin
  end

  test "provision_admin updates an existing account and is idempotent" do
    {user_id, email} = insert_account("ops@tryinstaclean.com", "old-password")

    assert {:ok, user} = Auth.provision_admin(email, "correct-horse")
    assert user.id == user_id
    assert Auth.admin?(user_id)
    assert {:ok, _} = Auth.login(email, "correct-horse")
    assert {:ok, _} = Auth.provision_admin(email, "correct-horse")
    assert Auth.admin?(user_id)
  end

  test "provision_admin creates a phone login that can use a password or OTP" do
    assert {:ok, user} =
             Auth.provision_admin(%{phone: "0555000000", password: "correct-horse"})

    assert user.phone == "+233555000000"
    assert user.admin
    assert {:ok, session} = Auth.login("0555000000", "correct-horse")
    assert session.user.id == user.id

    assert {:ok, _} = Auth.request_otp("0555000000")
    {_phone, code} = Application.get_env(:mithril, :test_last_otp)
    assert {:ok, otp_session} = Auth.verify_otp("0555000000", code)
    assert otp_session.user.id == user.id
    assert {:ok, me} = Auth.me(user.id)
    assert me.admin
  end

  test "provision_admin can attach the admin role to an existing public user by phone" do
    {user_id, _email} =
      insert_account("ops-phone@tryinstaclean.com", "old-password", phone: "+233555000222")

    Repo.query!("DELETE FROM public.mithril_auth_accounts WHERE user_id = $1::uuid", [
      dump_uuid(user_id)
    ])

    assert {:ok, user} = Auth.provision_admin(%{phone: "+233555000222"})
    assert user.id == user_id
    assert Auth.admin?(user_id)
    assert {:ok, _} = Auth.request_otp("+233555000222", %{"should_create_user" => false})
  end

  test "phone OTP on a non-admin account does not grant admin" do
    {_user_id, _email} =
      insert_account("staff@tryinstaclean.com", "correct-horse", phone: "+233555000333")

    assert {:ok, _} = Auth.request_otp("+233555000333")
    {_phone, code} = Application.get_env(:mithril, :test_last_otp)
    assert {:ok, session} = Auth.verify_otp("+233555000333", code)
    assert {:ok, me} = Auth.me(session.user.id)
    refute me.admin
    refute me.reviewer
  end

  test "me reports reviewer and staff from user_roles" do
    {user_id, _email} = insert_account("reviewer@tryinstaclean.com", "correct-horse")

    insert_catalog_role("reviewer")

    Repo.query!(
      "INSERT INTO public.user_roles (user_id, role_id) VALUES ($1::uuid, 'reviewer')",
      [
        dump_uuid(user_id)
      ]
    )

    assert {:ok, me} = Auth.me(user_id)
    refute me.admin
    assert me.reviewer
    assert Auth.reviewer?(user_id)
    assert Auth.staff?(user_id)
    assert Auth.staff_uuid?(user_id)
    refute Auth.staff_uuid?("not-a-uuid")
    refute Auth.admin?(user_id)
  end

  test "me reports cleaner role and verification state" do
    {user_id, _email} = insert_account("cleaner@tryinstaclean.com", "correct-horse")

    insert_catalog_role("cleaner")

    Repo.query!(
      "INSERT INTO public.user_roles (user_id, role_id) VALUES ($1::uuid, 'cleaner')",
      [dump_uuid(user_id)]
    )

    Repo.query!(
      "INSERT INTO public.cleaner_data (user_id, verified, status) VALUES ($1::uuid, true, 'active')",
      [dump_uuid(user_id)]
    )

    assert {:ok, me} = Auth.me(user_id)
    assert "cleaner" in me.roles
    assert me.cleanerVerified
    assert me.cleanerStatus == "active"
    assert me.location == nil
  end

  test "cleaner_activation_status reflects services, rate, payout, photo, and address" do
    {user_id, _email} = insert_account("activation@tryinstaclean.com", "correct-horse")
    uuid = dump_uuid(user_id)

    Repo.query!(
      """
      INSERT INTO public.profiles (id, user_id, avatar_url, address)
      VALUES ($1::uuid, $1::uuid, 'https://lh3.googleusercontent.com/a/photo', 'East Legon')
      """,
      [uuid]
    )

    Repo.query!(
      """
      INSERT INTO public.cleaner_data (
        user_id, verified, status, specialties, service_categories, hourly_rate, rate_set_at
      )
      VALUES (
        $1::uuid, true, 'active',
        ARRAY['standard_clean']::text[],
        ARRAY['cleaning']::text[],
        50,
        now()
      )
      """,
      [uuid]
    )

    Repo.query!(
      """
      INSERT INTO public.payout_methods (user_id, purpose, type, recipient_code)
      VALUES ($1::uuid, 'payout', 'bank', 'RCP_test')
      """,
      [uuid]
    )

    assert {:ok, status} = Auth.cleaner_activation_status(user_id)
    assert status.hasOfferedServices
    assert status.hasConfirmedRate
    assert status.hasPayoutMethod
    assert status.hasUploadedPhoto
    assert status.hasServiceLocation
    assert status.specialties == ["standard_clean"]
    assert status.hourlyRate == 50.0
  end

  test "me returns nil location when the profile has no coordinates" do
    {user_id, _email} = insert_account("no-location@tryinstaclean.com", "correct-horse")

    assert {:ok, me} = Auth.me(user_id)
    assert me.location == nil
    assert me.address == nil
    assert me.avatar_url == nil
  end

  test "check_availability reports another account's email as taken" do
    {owner_id, email} = insert_account("taken@tryinstaclean.com", "correct-horse")
    {other_id, _} = insert_account("other@tryinstaclean.com", "correct-horse")

    assert {:ok, %{exists: true}} =
             Auth.check_availability(%{"email" => "Taken@tryinstaclean.com"})

    assert {:ok, %{exists: false}} = Auth.check_availability(%{"email" => email}, owner_id)
    assert {:ok, %{exists: true}} = Auth.check_availability(%{"email" => email}, other_id)

    assert {:ok, %{exists: false}} =
             Auth.check_availability(%{"email" => "free@tryinstaclean.com"})
  end

  test "check_availability reports another account's phone as taken across Ghana formats" do
    {owner_id, _} =
      insert_account("phone-taken@tryinstaclean.com", "correct-horse", phone: "+233241234567")

    assert {:ok, %{exists: true}} = Auth.check_availability(%{"phone" => "0241234567"})

    assert {:ok, %{exists: false}} =
             Auth.check_availability(%{"phone" => "+233241234567"}, owner_id)

    assert {:ok, %{exists: false}} = Auth.check_availability(%{"phone" => "+233200000099"})
  end

  test "check_availability requires an email or phone" do
    assert {:error, :invalid_profile} = Auth.check_availability(%{})
  end

  test "check_availability treats inactive accounts as taken" do
    {user_id, email} = insert_account("inactive-available@tryinstaclean.com", "correct-horse")

    Repo.query!("UPDATE public.users SET status = 'inactive' WHERE id = $1::uuid", [
      dump_uuid(user_id)
    ])

    assert {:ok, %{exists: true}} = Auth.check_availability(%{"email" => email})
    assert {:error, :email_taken} = Auth.register(email, "another-password")
  end

  test "check_availability treats a legacy public.users email as taken" do
    email = "legacy-available@tryinstaclean.com"
    insert_legacy_user(email, phone: "+233200000088")

    assert {:ok, %{exists: true}} = Auth.check_availability(%{"email" => String.upcase(email)})
    assert {:ok, %{exists: true}} = Auth.check_availability(%{"phone" => "0200000088"})
    assert {:error, :email_taken} = Auth.register(email, "another-password")
  end

  test "update_profile upserts profiles, phone, and onboarding roles" do
    {user_id, email} = insert_account("profile@tryinstaclean.com", "correct-horse")

    assert {:ok, me} =
             Auth.update_profile(user_id, %{
               "first_name" => "Arthur",
               "last_name" => "Decker",
               "phone" => "+233200000001",
               "email" => email,
               "address" => "East Legon",
               "location_wkt" => "POINT(-0.205 5.56)",
               "roles" => ["customer", "cleaner", "admin"]
             })

    assert me.phone == "+233200000001"
    assert me.name == "Arthur Decker"
    assert me.first_name == "Arthur"
    assert me.last_name == "Decker"
    assert me.address == "East Legon"
    assert "customer" in me.roles
    assert "cleaner" in me.roles
    refute "admin" in me.roles

    [[firstname, lastname, fullname, address, location_wkt]] =
      Repo.query!(
        """
        SELECT firstname, lastname, fullname, address, location_wkt
        FROM public.profiles
        WHERE id = $1::uuid
        """,
        [dump_uuid(user_id)]
      ).rows

    assert firstname == "Arthur"
    assert lastname == "Decker"
    assert fullname == "Arthur Decker"
    assert address == "East Legon"
    assert location_wkt == "POINT(-0.205 5.56)"
    assert me.location.latitude == 5.56
    assert me.location.longitude == -0.205
    assert me.location.location_wkt == "POINT(-0.205 5.56)"

    catalog_ids =
      Repo.query!("SELECT id FROM public.roles ORDER BY id").rows
      |> Enum.map(&hd/1)

    assert "customer" in catalog_ids
    assert "cleaner" in catalog_ids
    refute "admin" in catalog_ids

    assert {:ok, _} =
             Auth.update_profile(user_id, %{
               "first_name" => "Arthur",
               "last_name" => "Decker",
               "phone" => "+233200000001",
               "roles" => ["customer", "cleaner"]
             })

    [[role_count]] =
      Repo.query!(
        "SELECT count(*) FROM public.user_roles WHERE user_id = $1::uuid AND role_id IN ('customer', 'cleaner')",
        [dump_uuid(user_id)]
      ).rows

    assert role_count == 2
  end

  test "update_profile preserves optional profile fields when omitted" do
    {user_id, email} = insert_account("profile-preserve@tryinstaclean.com", "correct-horse")

    assert {:ok, _} =
             Auth.update_profile(user_id, %{
               "first_name" => "Ama",
               "last_name" => "Mensah",
               "phone" => "+233200000010",
               "email" => email,
               "avatar_url" => "https://example.com/avatar.png",
               "address" => "Airport Residential",
               "location_wkt" => "POINT(-0.18 5.60)"
             })

    assert {:ok, me} =
             Auth.update_profile(user_id, %{
               "first_name" => "Ama",
               "last_name" => "Boateng",
               "phone" => "+233200000010"
             })

    assert me.location.latitude == 5.60
    assert me.location.longitude == -0.18
    assert me.location.location_wkt == "POINT(-0.18 5.60)"

    [[avatar_url, address, location_wkt]] =
      Repo.query!(
        "SELECT avatar_url, address, location_wkt FROM public.profiles WHERE id = $1::uuid",
        [dump_uuid(user_id)]
      ).rows

    assert avatar_url == "https://example.com/avatar.png"
    assert address == "Airport Residential"
    assert location_wkt == "POINT(-0.18 5.60)"

    [[public_email]] =
      Repo.query!("SELECT email FROM public.users WHERE id = $1::uuid", [dump_uuid(user_id)]).rows

    [[account_email]] =
      Repo.query!("SELECT email FROM public.mithril_auth_accounts WHERE user_id = $1::uuid", [
        dump_uuid(user_id)
      ]).rows

    [[auth_email]] =
      Repo.query!("SELECT email FROM auth.users WHERE id = $1::uuid", [dump_uuid(user_id)]).rows

    assert public_email == email
    assert account_email == email
    assert auth_email == email
  end

  test "update_profile keeps phone identity synchronized with the profile phone" do
    {user_id, _email} =
      insert_account(
        "phone-identity@tryinstaclean.com",
        "correct-horse",
        phone: "+233200000020"
      )

    Repo.query!(
      """
      INSERT INTO public.mithril_auth_identities (user_id, provider, provider_subject)
      VALUES ($1::uuid, 'phone', $2)
      """,
      [dump_uuid(user_id), "+233200000020"]
    )

    assert {:ok, _} =
             Auth.update_profile(user_id, %{
               "first_name" => "Kojo",
               "phone" => "+233200000021"
             })

    [[provider_subject]] =
      Repo.query!(
        """
        SELECT provider_subject
        FROM public.mithril_auth_identities
        WHERE user_id = $1::uuid AND provider = 'phone'
        """,
        [dump_uuid(user_id)]
      ).rows

    assert provider_subject == "+233200000021"
  end

  test "update_profile rolls back when the new phone conflicts with another phone identity" do
    {user_id, _email} =
      insert_account(
        "phone-identity-owner@tryinstaclean.com",
        "correct-horse",
        phone: "+233200000030"
      )

    {other_user_id, _other_email} =
      insert_account("phone-identity-other@tryinstaclean.com", "correct-horse")

    Repo.query!(
      """
      INSERT INTO public.mithril_auth_identities (user_id, provider, provider_subject)
      VALUES ($1::uuid, 'phone', $2), ($3::uuid, 'phone', $4)
      """,
      [
        dump_uuid(user_id),
        "+233200000030",
        dump_uuid(other_user_id),
        "+233200000031"
      ]
    )

    assert {:error, :phone_taken} =
             Auth.update_profile(user_id, %{
               "first_name" => "Efua",
               "phone" => "+233200000031"
             })

    [[public_phone]] =
      Repo.query!("SELECT phone FROM public.users WHERE id = $1::uuid", [dump_uuid(user_id)]).rows

    [[account_phone]] =
      Repo.query!("SELECT phone FROM public.mithril_auth_accounts WHERE user_id = $1::uuid", [
        dump_uuid(user_id)
      ]).rows

    [[auth_phone]] =
      Repo.query!("SELECT phone FROM auth.users WHERE id = $1::uuid", [dump_uuid(user_id)]).rows

    [[provider_subject]] =
      Repo.query!(
        """
        SELECT provider_subject
        FROM public.mithril_auth_identities
        WHERE user_id = $1::uuid AND provider = 'phone'
        """,
        [dump_uuid(user_id)]
      ).rows

    assert public_phone == "+233200000030"
    assert account_phone == "+233200000030"
    assert auth_phone == "+233200000030"
    assert provider_subject == "+233200000030"
  end

  test "update_profile clears email consistently when explicitly blank" do
    {user_id, _email} = insert_account("clear-email@tryinstaclean.com", "correct-horse")

    assert {:ok, _} =
             Auth.update_profile(user_id, %{
               "first_name" => "Akosua",
               "phone" => "+233200000040",
               "email" => ""
             })

    [[public_email]] =
      Repo.query!("SELECT email FROM public.users WHERE id = $1::uuid", [dump_uuid(user_id)]).rows

    [[account_email]] =
      Repo.query!("SELECT email FROM public.mithril_auth_accounts WHERE user_id = $1::uuid", [
        dump_uuid(user_id)
      ]).rows

    [[auth_email]] =
      Repo.query!("SELECT email FROM auth.users WHERE id = $1::uuid", [dump_uuid(user_id)]).rows

    assert public_email == nil
    assert account_email == nil
    assert auth_email == nil
  end

  test "update_profile rejects an invalid phone" do
    {user_id, _email} = insert_account("invalid-phone@tryinstaclean.com", "correct-horse")

    assert {:error, :invalid_phone} =
             Auth.update_profile(user_id, %{
               "first_name" => "Ama",
               "phone" => "not-a-phone"
             })
  end

  test "update_profile rejects a phone already used by another account" do
    {_first_id, _first_email} =
      insert_account("first-profile@tryinstaclean.com", "correct-horse", phone: "+233200000002")

    {user_id, _email} = insert_account("second-profile@tryinstaclean.com", "correct-horse")

    assert {:error, :phone_taken} =
             Auth.update_profile(user_id, %{
               "first_name" => "Ama",
               "phone" => "+233200000002"
             })
  end

  test "login rejects inactive accounts" do
    {user_id, email} = insert_account("inactive@example.com", "correct-horse")

    Repo.query!("UPDATE public.users SET status = 'suspended' WHERE id = $1::uuid", [
      dump_uuid(user_id)
    ])

    assert {:error, :invalid_credentials} = Auth.login(email, "correct-horse")
  end

  test "login rejects a wrong password" do
    {_user_id, email} = insert_account("wrong@example.com", "correct-horse")
    assert {:error, :invalid_credentials} = Auth.login(email, "nope")
  end

  test "refresh rotates the refresh token" do
    {_user_id, email} = insert_account("refresh@example.com", "correct-horse")
    {:ok, session} = Auth.login(email, "correct-horse")

    assert {:ok, rotated} = Auth.refresh(session.refresh_token)
    assert rotated.access_token != session.access_token
    assert {:error, :invalid_refresh_token} = Auth.refresh(session.refresh_token)
  end

  test "refresh rejects a token after the account is suspended" do
    {user_id, email} = insert_account("suspended-refresh@example.com", "correct-horse")
    {:ok, session} = Auth.login(email, "correct-horse")

    Repo.query!("UPDATE public.users SET status = 'suspended' WHERE id = $1::uuid", [
      dump_uuid(user_id)
    ])

    assert {:error, :invalid_refresh_token} = Auth.refresh(session.refresh_token)
  end

  test "password change syncs legacy hashes and revokes refresh sessions" do
    {user_id, email} = insert_account("password@example.com", "old-password")
    {:ok, session} = Auth.login(email, "old-password")

    assert :ok = Auth.set_password(user_id, "new-password", "old-password")
    assert {:error, :invalid_refresh_token} = Auth.refresh(session.refresh_token)
    assert {:error, :invalid_credentials} = Auth.login(email, "old-password")
    assert {:ok, _session} = Auth.login(email, "new-password")

    [[mithril_hash, public_hash, auth_hash]] =
      Repo.query!(
        """
        SELECT a.password_hash, u.password_hash, au.encrypted_password
        FROM public.mithril_auth_accounts a
        JOIN public.users u ON u.id = a.user_id
        JOIN auth.users au ON au.id = a.user_id
        WHERE a.user_id = $1::uuid
        """,
        [dump_uuid(user_id)]
      ).rows

    assert Bcrypt.verify_pass("new-password", mithril_hash)
    assert Bcrypt.verify_pass("new-password", public_hash)
    assert Bcrypt.verify_pass("new-password", auth_hash)
  end

  test "register survives the existing auth user sync trigger and fills required hashes" do
    assert {:ok, session} = Auth.register("new-user@example.com", "register-password")

    [[public_hash, auth_hash]] =
      Repo.query!(
        """
        SELECT u.password_hash, au.encrypted_password
        FROM public.users u
        JOIN auth.users au ON au.id = u.id
        WHERE u.id = $1::uuid
        """,
        [dump_uuid(session.user.id)]
      ).rows

    assert Bcrypt.verify_pass("register-password", public_hash)
    assert Bcrypt.verify_pass("register-password", auth_hash)
    assert {:ok, _session} = Auth.login("new-user@example.com", "register-password")
  end

  test "phone OTP creates a session" do
    assert {:ok, %{ok: true}} = Auth.request_otp("0244123456")
    {_phone, code} = Application.get_env(:mithril, :test_last_otp)

    assert {:ok, session} = Auth.verify_otp("+233244123456", code)
    assert session.user.phone == "+233244123456"

    assert {:ok, %{"sub" => _, "phone" => "+233244123456"}} =
             Token.verify_access(session.access_token)
  end

  test "phone OTP is single-use" do
    assert {:ok, %{ok: true}} = Auth.request_otp("0244123456")
    {_phone, code} = Application.get_env(:mithril, :test_last_otp)

    assert {:ok, _session} = Auth.verify_otp("0244123456", code)
    assert {:error, :invalid_otp} = Auth.verify_otp("0244123456", code)
  end

  test "phone OTP rejects a wrong code" do
    assert {:ok, _} = Auth.request_otp("0244123456")
    {_phone, code} = Application.get_env(:mithril, :test_last_otp)
    wrong_code = if code == "000000", do: "999999", else: "000000"

    assert {:error, :invalid_otp} = Auth.verify_otp("0244123456", wrong_code)
  end

  test "phone OTP stops accepting attempts after five failures" do
    assert {:ok, _} = Auth.request_otp("0244123456")
    {_phone, code} = Application.get_env(:mithril, :test_last_otp)
    wrong_code = if code == "000000", do: "999999", else: "000000"

    for _ <- 1..5 do
      assert {:error, :invalid_otp} = Auth.verify_otp("0244123456", wrong_code)
    end

    assert {:error, :invalid_otp} = Auth.verify_otp("0244123456", code)
  end

  test "phone OTP can require an existing account" do
    assert {:error, :user_not_found} =
             Auth.request_otp("0244123456", %{"should_create_user" => false})
  end

  test "phone OTP caps sends per phone each hour" do
    for _ <- 1..5 do
      Repo.query!("""
      INSERT INTO public.mithril_auth_otps
        (phone, code_hash, expires_at, inserted_at)
      VALUES ('+233244123456', 'old', now() + interval '5 minutes', now() - interval '1 minute')
      """)
    end

    assert {:error, :otp_rate_limited} = Auth.request_otp("0244123456")
  end

  test "phone OTP caps sends per client IP each hour" do
    for i <- 1..25 do
      Repo.query!(
        """
        INSERT INTO public.mithril_auth_otps
          (phone, code_hash, expires_at, request_ip, inserted_at)
        VALUES ($1, 'old', now() + interval '5 minutes', '203.0.113.10', now() - interval '1 minute')
        """,
        ["+1555000#{String.pad_leading(Integer.to_string(i), 4, "0")}"]
      )
    end

    assert {:error, :otp_rate_limited} =
             Auth.request_otp("0244123456", %{"request_ip" => "203.0.113.10"})
  end

  test "configured test phone numbers skip SMS and accept a fixed OTP" do
    previous_adapter = Application.get_env(:mithril, :sms_adapter)
    previous_phones = Application.get_env(:mithril, :sms_test_phones)

    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Disabled)
    Application.put_env(:mithril, :sms_test_phones, %{"+233555000000" => "424242"})

    on_exit(fn ->
      Application.put_env(:mithril, :sms_adapter, previous_adapter)

      if previous_phones do
        Application.put_env(:mithril, :sms_test_phones, previous_phones)
      else
        Application.delete_env(:mithril, :sms_test_phones)
      end
    end)

    assert Auth.methods().phone
    assert {:ok, %{ok: true}} = Auth.request_otp("0555000000")
    assert {:error, :invalid_otp} = Auth.verify_otp("0555000000", "000000")
    assert {:ok, session} = Auth.verify_otp("0555000000", "424242")
    assert session.user.phone == "+233555000000"
    assert {:error, :sms_not_configured} = Auth.request_otp("0244123456")
  end

  test "google oauth issues a session and links later logins" do
    assert {:ok, first} = Auth.oauth("google", "google-id-token")
    assert first.user.email == "google@example.com"
    assert first.user.name == "Google User"

    [[firstname, lastname, fullname]] =
      Repo.query!(
        "SELECT firstname, lastname, fullname FROM public.profiles WHERE id = $1::uuid",
        [dump_uuid(first.user.id)]
      ).rows

    assert firstname == "Google"
    assert lastname == "User"
    assert fullname == "Google User"

    assert {:ok, second} = Auth.oauth("google", "google-id-token")
    assert second.user.id == first.user.id
  end

  test "google oauth links to an existing account without creating a duplicate user" do
    {user_id, _email} = insert_account("google@example.com", "correct-horse")

    assert {:ok, session} = Auth.oauth("google", "google-id-token")
    assert session.user.id == user_id

    [[count]] = Repo.query!("SELECT count(*) FROM public.users").rows
    assert count == 1
  end

  test "google oauth links to an Instaclean user who has not used Direct yet" do
    user_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO auth.users (id, email, encrypted_password) VALUES ($1, $2, $3)",
      [dump_uuid(user_id), "google@example.com", ""]
    )

    assert {:ok, session} = Auth.oauth("google", "google-id-token")
    assert session.user.id == user_id
    assert session.user.email == "google@example.com"

    [[count]] = Repo.query!("SELECT count(*) FROM public.users").rows
    assert count == 1
  end

  test "facebook oauth issues a session" do
    assert {:ok, session} = Auth.oauth("facebook", "facebook-access-token")
    assert session.user.email == "facebook@example.com"
  end

  test "methods lists the Instaclean sign-in options" do
    assert Auth.methods() == %{
             email_password: true,
             phone: true,
             google: true,
             facebook: true
           }
  end

  defp insert_legacy_user(email, opts) do
    user_id = Ecto.UUID.generate()
    {:ok, user_uuid} = Ecto.UUID.dump(user_id)
    hash = Bcrypt.hash_pwd_salt("legacy-password")
    phone = Keyword.get(opts, :phone)

    Repo.query!(
      "INSERT INTO auth.users (id, email, phone, encrypted_password) VALUES ($1, $2, $3, $4)",
      [user_uuid, email, phone, hash]
    )

    Repo.query!(
      "UPDATE public.users SET email = $2, phone = $3, password_hash = $4 WHERE id = $1",
      [user_uuid, email, phone, hash]
    )

    {user_id, email}
  end

  defp insert_catalog_role(role_id) do
    Repo.query!(
      "INSERT INTO public.roles (id, description) VALUES ($1, $1) ON CONFLICT (id) DO NOTHING",
      [role_id]
    )
  end

  defp insert_account(email, password, opts \\ []) do
    user_id = Ecto.UUID.generate()
    {:ok, user_uuid} = Ecto.UUID.dump(user_id)
    hash = Bcrypt.hash_pwd_salt(password)
    phone = Keyword.get(opts, :phone)

    Repo.query!(
      "INSERT INTO auth.users (id, email, phone, encrypted_password) VALUES ($1, $2, $3, $4)",
      [user_uuid, email, phone, hash]
    )

    Repo.query!(
      "UPDATE public.users SET email = $2, phone = $3, password_hash = $4 WHERE id = $1",
      [user_uuid, email, phone, hash]
    )

    Repo.query!(
      "INSERT INTO public.mithril_auth_accounts (user_id, email, phone, password_hash) VALUES ($1, $2, $3, $4)",
      [user_uuid, email, phone, hash]
    )

    {user_id, email}
  end

  defp dump_uuid(user_id) do
    {:ok, dumped} = Ecto.UUID.dump(user_id)
    dumped
  end

  defp oauth_http(url) do
    cond do
      String.contains?(url, "oauth2.googleapis.com") ->
        {:ok,
         %{
           status: 200,
           body: %{
             "sub" => "google-sub-1",
             "aud" => "test-google-client",
             "email" => "google@example.com",
             "email_verified" => true,
             "name" => "Google User"
           }
         }}

      String.contains?(url, "debug_token") ->
        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"is_valid" => true, "app_id" => "test-facebook-app"}}
         }}

      String.contains?(url, "graph.facebook.com/me") ->
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => "facebook-1",
             "email" => "facebook@example.com",
             "name" => "Facebook User"
           }
         }}

      true ->
        {:error, :unexpected_url}
    end
  end
end
