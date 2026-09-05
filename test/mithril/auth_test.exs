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
      phone text,
      password_hash text NOT NULL,
      status text DEFAULT 'active',
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now()
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

  test "phone OTP rejects a wrong code" do
    assert {:ok, _} = Auth.request_otp("0244123456")
    assert {:error, :invalid_otp} = Auth.verify_otp("0244123456", "000000")
  end

  test "phone OTP can require an existing account" do
    assert {:error, :user_not_found} =
             Auth.request_otp("0244123456", %{"should_create_user" => false})
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

    assert {:ok, second} = Auth.oauth("google", "google-id-token")
    assert second.user.id == first.user.id
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
