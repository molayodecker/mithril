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
      email text,
      created_at timestamptz,
      updated_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY REFERENCES auth.users(id),
      email text UNIQUE,
      status text DEFAULT 'active'
    )
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

  defp insert_account(email, password) do
    user_id = Ecto.UUID.generate()
    {:ok, user_uuid} = Ecto.UUID.dump(user_id)
    hash = Bcrypt.hash_pwd_salt(password)

    Repo.query!("INSERT INTO auth.users (id, email) VALUES ($1, $2)", [user_uuid, email])
    Repo.query!("INSERT INTO public.users (id, email) VALUES ($1, $2)", [user_uuid, email])

    Repo.query!(
      "INSERT INTO public.mithril_auth_accounts (user_id, email, password_hash) VALUES ($1, $2, $3)",
      [user_uuid, email, hash]
    )

    {user_id, email}
  end
end
