defmodule Mithril.Auth do
  @moduledoc """
  Email/password login for Mithril. Issues JWTs for API clients such as Direct.
  """

  require Logger

  alias Mithril.Auth.Token
  alias Mithril.Repo

  def login(email, password) when is_binary(email) and is_binary(password) do
    email = normalize_email(email)

    with {:ok, account} <- fetch_account(email),
         :ok <- verify_password(password, account.password_hash),
         {:ok, tokens} <- issue_session(account) do
      {:ok, tokens}
    else
      :error -> {:error, :invalid_credentials}
      {:error, :invalid_credentials} -> {:error, :invalid_credentials}
      {:error, :password_not_set} -> {:error, :password_not_set}
      {:error, reason} -> {:error, reason}
    end
  end

  def login(_, _), do: {:error, :invalid_credentials}

  def refresh(refresh_token) when is_binary(refresh_token) do
    hash = hash_refresh(refresh_token)

    case Repo.query(
           """
           SELECT user_id::text
           FROM public.mithril_refresh_tokens
           WHERE token_hash = $1
             AND revoked_at IS NULL
             AND expires_at > now()
           """,
           [hash]
         ) do
      {:ok, %{num_rows: 1, rows: [[user_id]]}} ->
        _ = revoke_refresh(hash)

        with {:ok, account} <- fetch_account_by_id(user_id),
             {:ok, tokens} <- issue_session(account) do
          {:ok, tokens}
        end

      {:ok, _} ->
        {:error, :invalid_refresh_token}

      {:error, error} ->
        database_error(error)
    end
  end

  def refresh(_), do: {:error, :invalid_refresh_token}

  def logout(refresh_token) when is_binary(refresh_token) do
    _ = revoke_refresh(hash_refresh(refresh_token))
    :ok
  end

  def logout(_), do: :ok

  def me(user_id) when is_binary(user_id) do
    case Repo.query(
           """
           SELECT a.user_id::text, a.email, u.status::text
           FROM public.mithril_auth_accounts a
           JOIN public.users u ON u.id = a.user_id
           WHERE a.user_id = $1::uuid
           """,
           [dump_uuid(user_id)]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, email, status]]}} ->
        {:ok, %{id: id, email: email, status: status}}

      {:ok, _} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  def set_password(user_id, password, current_password \\ nil)

  def set_password(_user_id, password, _current_password)
      when not is_binary(password) or password == "" do
    {:error, :weak_password}
  end

  def set_password(user_id, password, current_password)
      when is_binary(user_id) and is_binary(password) do
    with :ok <- validate_password(password),
         {:ok, account} <- fetch_account_by_id(user_id),
         :ok <- authorize_password_change(account, current_password) do
      hash = Bcrypt.hash_pwd_salt(password)

      case Repo.query(
             """
             UPDATE public.mithril_auth_accounts
             SET password_hash = $2, updated_at = now()
             WHERE user_id = $1::uuid
             """,
             [dump_uuid(user_id), hash]
           ) do
        {:ok, _} -> :ok
        {:error, error} -> database_error(error)
      end
    end
  end

  def register(email, password) when is_binary(email) and is_binary(password) do
    email = normalize_email(email)

    with :ok <- validate_email(email),
         :ok <- validate_password(password),
         {:ok, user_id} <- insert_user(email),
         :ok <- insert_account(user_id, email, Bcrypt.hash_pwd_salt(password)),
         {:ok, account} <- fetch_account_by_id(user_id),
         {:ok, tokens} <- issue_session(account) do
      {:ok, tokens}
    end
  end

  def register(_, _), do: {:error, :invalid_email}

  defp issue_session(account) do
    with {:ok, access_token, _claims} <- Token.issue(account.user_id, account.email),
         {:ok, refresh_token} <- persist_refresh(account.user_id) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         token_type: "bearer",
         expires_in: Token.access_ttl(),
         user: %{id: account.user_id, email: account.email}
       }}
    end
  end

  defp persist_refresh(user_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    hash = hash_refresh(token)
    expires_at = DateTime.add(DateTime.utc_now(), Token.refresh_ttl(), :second)

    case Repo.query(
           """
           INSERT INTO public.mithril_refresh_tokens (user_id, token_hash, expires_at)
           VALUES ($1::uuid, $2, $3)
           """,
           [dump_uuid(user_id), hash, expires_at]
         ) do
      {:ok, _} -> {:ok, token}
      {:error, error} -> database_error(error)
    end
  end

  defp revoke_refresh(hash) do
    Repo.query(
      "UPDATE public.mithril_refresh_tokens SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL",
      [hash]
    )
  end

  defp fetch_account(email) do
    case Repo.query(
           """
           SELECT user_id::text, email, password_hash
           FROM public.mithril_auth_accounts
           WHERE lower(email) = $1
           """,
           [email]
         ) do
      {:ok, %{num_rows: 1, rows: [[user_id, stored_email, password_hash]]}} ->
        {:ok, %{user_id: user_id, email: stored_email, password_hash: password_hash}}

      {:ok, _} ->
        _ = Bcrypt.no_user_verify()
        :error

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_account_by_id(user_id) do
    case Repo.query(
           """
           SELECT user_id::text, email, password_hash
           FROM public.mithril_auth_accounts
           WHERE user_id = $1::uuid
           """,
           [dump_uuid(user_id)]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, email, password_hash]]}} ->
        {:ok, %{user_id: id, email: email, password_hash: password_hash}}

      {:ok, _} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp verify_password(_password, hash) when hash in [nil, ""] do
    {:error, :password_not_set}
  end

  defp verify_password(password, hash) do
    if Bcrypt.verify_pass(password, hash) do
      :ok
    else
      {:error, :invalid_credentials}
    end
  end

  defp authorize_password_change(%{password_hash: hash}, _current) when hash in [nil, ""] do
    :ok
  end

  defp authorize_password_change(%{password_hash: hash}, current) when is_binary(current) do
    verify_password(current, hash)
  end

  defp authorize_password_change(_account, _current) do
    {:error, :current_password_required}
  end

  defp insert_user(email) do
    user_id = Ecto.UUID.generate()

    Repo.transaction(fn ->
      with {:ok, _} <-
             Repo.query(
               """
               INSERT INTO auth.users (id, email, created_at, updated_at)
               VALUES ($1::uuid, $2, now(), now())
               """,
               [dump_uuid(user_id), email]
             ),
           {:ok, _} <-
             Repo.query(
               """
               INSERT INTO public.users (id, email, status, created_at, updated_at)
               VALUES ($1::uuid, $2, 'active', now(), now())
               """,
               [dump_uuid(user_id), email]
             ) do
        user_id
      else
        {:error, %{postgres: %{code: :unique_violation}}} ->
          Repo.rollback(:email_taken)

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, user_id} -> {:ok, user_id}
      {:error, :email_taken} -> {:error, :email_taken}
      {:error, error} -> database_error(error)
    end
  end

  defp insert_account(user_id, email, password_hash) do
    case Repo.query(
           """
           INSERT INTO public.mithril_auth_accounts (user_id, email, password_hash)
           VALUES ($1::uuid, $2, $3)
           """,
           [dump_uuid(user_id), email, password_hash]
         ) do
      {:ok, _} -> :ok
      {:error, %{postgres: %{code: :unique_violation}}} -> {:error, :email_taken}
      {:error, error} -> database_error(error)
    end
  end

  defp validate_email(email) do
    if String.contains?(email, "@") and String.length(email) >= 3 and String.length(email) <= 255 do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_password(password) do
    if String.length(password) >= 8 do
      :ok
    else
      {:error, :weak_password}
    end
  end

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()

  defp dump_uuid(user_id) do
    case Ecto.UUID.dump(user_id) do
      {:ok, dumped} -> dumped
      :error -> user_id
    end
  end

  defp hash_refresh(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp database_error(error) do
    Logger.error("Auth database operation failed: #{Exception.message(error)}")
    {:error, :database_unavailable}
  end
end
