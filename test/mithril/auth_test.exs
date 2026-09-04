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

    Repo.query!("DROP TABLE IF EXISTS public.mithril_refresh_tokens CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.mithril_auth_accounts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")
    Repo.query!("DROP SCHEMA IF EXISTS auth CASCADE")
    Repo.query!("CREATE SCHEMA auth")

    Repo.query!("""
    CREATE TABLE auth.users (
      id uuid PRIMARY KEY,
      email text UNIQUE,
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
      email text NOT NULL UNIQUE,
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

    :ok
  end

  test "login issues a JWT for an existing password" do
    {user_id, email} = insert_account("login@example.com", "correct-horse")

    assert {:ok, session} = Auth.login(email, "correct-horse")
    assert session.user.id == user_id
    assert session.token_type == "bearer"

    assert {:ok, %{"sub" => ^user_id, "email" => ^email}} =
             Token.verify_access(session.access_token)
  end

  test "login accepts the user's phone even when the account also has an email" do
    {_user_id, _email} =
      insert_account("phone-login@example.com", "correct-horse", phone: "+233555000111")

    assert {:ok, session} = Auth.login("+233555000111", "correct-horse")
    assert session.user.email == "phone-login@example.com"
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

  defp insert_account(email, password, opts \\ []) do
    user_id = Ecto.UUID.generate()
    {:ok, user_uuid} = Ecto.UUID.dump(user_id)
    hash = Bcrypt.hash_pwd_salt(password)
    phone = Keyword.get(opts, :phone)

    Repo.query!(
      "INSERT INTO auth.users (id, email, encrypted_password) VALUES ($1, $2, $3)",
      [user_uuid, email, hash]
    )

    Repo.query!(
      "UPDATE public.users SET email = $2, phone = $3, password_hash = $4 WHERE id = $1",
      [user_uuid, email, phone, hash]
    )

    Repo.query!(
      "INSERT INTO public.mithril_auth_accounts (user_id, email, password_hash) VALUES ($1, $2, $3)",
      [user_uuid, email, hash]
    )

    {user_id, email}
  end

  defp dump_uuid(user_id) do
    {:ok, dumped} = Ecto.UUID.dump(user_id)
    dumped
  end
end
