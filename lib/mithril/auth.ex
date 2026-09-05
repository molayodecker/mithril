defmodule Mithril.Auth do
  @moduledoc """
  Mithril login for API clients. Supports email/password, phone OTP,
  Google, and Facebook, and issues JWTs.
  """

  require Logger

  alias Mithril.Auth.OAuth
  alias Mithril.Auth.Phone
  alias Mithril.Auth.SMS
  alias Mithril.Auth.TestPhones
  alias Mithril.Auth.Token
  alias Mithril.Repo

  @otp_ttl_seconds 300
  @otp_resend_seconds 30
  @otp_max_attempts 5
  @otp_phone_hourly_limit 5
  @otp_ip_hourly_limit 25

  def methods do
    %{
      email_password: true,
      phone: SMS.configured?(),
      google: OAuth.google_configured?(),
      facebook: OAuth.facebook_configured?()
    }
  end

  def login(identifier, password) when is_binary(identifier) and is_binary(password) do
    identifier = normalize_login(identifier)

    with {:ok, account} <- fetch_account_for_login(identifier),
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

  def request_otp(phone, opts \\ %{}) do
    should_create_user? =
      truthy?(Map.get(opts, "should_create_user", Map.get(opts, :should_create_user, true)))

    request_ip =
      normalize_request_ip(Map.get(opts, "request_ip", Map.get(opts, :request_ip)))

    with {:ok, phone} <- normalize_phone(phone),
         :ok <- ensure_sms_configured(phone),
         :ok <- ensure_otp_account(phone, should_create_user?),
         {:ok, code} <- create_otp(phone, request_ip),
         :ok <- SMS.send_otp(phone, code) do
      {:ok, %{ok: true}}
    end
  end

  def verify_otp(phone, token) when is_binary(token) do
    with {:ok, phone} <- normalize_phone(phone),
         {:ok, account} <- consume_otp(phone, token),
         {:ok, tokens} <- issue_session(account) do
      {:ok, tokens}
    end
  end

  def verify_otp(_, _), do: {:error, :invalid_otp}

  def oauth(provider, token) when provider in ["google", "facebook"] and is_binary(token) do
    with {:ok, identity} <- verify_oauth(provider, token),
         {:ok, account} <- find_or_create_oauth_account(identity),
         {:ok, tokens} <- issue_session(account) do
      {:ok, tokens}
    end
  end

  def oauth(_, _), do: {:error, :invalid_provider}

  def refresh(refresh_token) when is_binary(refresh_token) do
    hash = hash_refresh(refresh_token)

    Repo.transaction(fn ->
      with {:ok, user_id} <- claim_refresh(hash),
           {:ok, account} <- fetch_account_by_id(user_id),
           {:ok, tokens} <- issue_session(account) do
        tokens
      else
        {:error, :not_found} -> Repo.rollback(:invalid_refresh_token)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, tokens} -> {:ok, tokens}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh(_), do: {:error, :invalid_refresh_token}

  def logout(refresh_token) when is_binary(refresh_token) do
    _ = revoke_refresh(hash_refresh(refresh_token))
    :ok
  end

  def logout(_), do: :ok

  def me(user_id) when is_binary(user_id) do
    case fetch_account_by_id(user_id) do
      {:ok, account} ->
        {:ok, Map.put(session_user(account), :status, account.status)}

      other ->
        other
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
      password_hash = Bcrypt.hash_pwd_salt(password)
      update_password_and_revoke_sessions(user_id, password_hash)
    end
  end

  def register(email, password) when is_binary(email) and is_binary(password) do
    email = normalize_login(email)

    with :ok <- validate_email(email),
         :ok <- validate_password(password) do
      password_hash = Bcrypt.hash_pwd_salt(password)

      with {:ok, user_id} <-
             insert_user_and_account(%{email: email, password_hash: password_hash}),
           {:ok, account} <- fetch_account_by_id(user_id),
           {:ok, tokens} <- issue_session(account) do
        {:ok, tokens}
      end
    end
  end

  def register(_, _), do: {:error, :invalid_email}

  defp issue_session(account) do
    user = session_user(account)

    with {:ok, access_token, _claims} <-
           Token.issue(account.user_id, %{email: user.email, phone: user.phone}),
         {:ok, refresh_token} <- persist_refresh(account.user_id) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         token_type: "bearer",
         expires_in: Token.access_ttl(),
         user: user
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

  defp claim_refresh(hash) do
    case Repo.query(
           """
           UPDATE public.mithril_refresh_tokens
           SET revoked_at = now()
           WHERE token_hash = $1
             AND revoked_at IS NULL
             AND expires_at > now()
           RETURNING user_id::text
           """,
           [hash]
         ) do
      {:ok, %{num_rows: 1, rows: [[user_id]]}} -> {:ok, user_id}
      {:ok, _} -> {:error, :invalid_refresh_token}
      {:error, error} -> database_error(error)
    end
  end

  defp revoke_refresh(hash) do
    Repo.query(
      "UPDATE public.mithril_refresh_tokens SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL",
      [hash]
    )
  end

  defp fetch_account_for_login(identifier) do
    phone =
      case Phone.normalize(identifier) do
        {:ok, value} -> value
        :error -> nil
      end

    case Repo.query(
           """
           SELECT a.user_id::text, a.email, a.phone, a.password_hash, u.status::text
           FROM public.mithril_auth_accounts a
           JOIN public.users u ON u.id = a.user_id
           WHERE u.status::text = 'active'
             AND (
               lower(coalesce(a.email, '')) = $1
               OR a.phone = $1
               OR a.phone = $2
               OR lower(btrim(coalesce(u.phone, ''))) = $1
               OR lower(btrim(coalesce(u.phone, ''))) = coalesce($2, '')
             )
           """,
           [identifier, phone]
         ) do
      {:ok, %{num_rows: 1, rows: [[user_id, email, stored_phone, password_hash, status]]}} ->
        {:ok, account(user_id, email, stored_phone, password_hash, status)}

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
           SELECT a.user_id::text, a.email, a.phone, a.password_hash, u.status::text
           FROM public.mithril_auth_accounts a
           JOIN public.users u ON u.id = a.user_id
           WHERE a.user_id = $1::uuid
             AND u.status::text = 'active'
           """,
           [dump_uuid(user_id)]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, email, phone, password_hash, status]]}} ->
        {:ok, account(id, email, phone, password_hash, status)}

      {:ok, _} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_account_by_phone(phone) do
    case Repo.query(
           """
           SELECT a.user_id::text, a.email, a.phone, a.password_hash, u.status::text
           FROM public.mithril_auth_accounts a
           JOIN public.users u ON u.id = a.user_id
           WHERE u.status::text = 'active'
             AND (a.phone = $1 OR lower(coalesce(a.email, '')) = $1)
           """,
           [phone]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, email, stored_phone, password_hash, status]]}} ->
        {:ok, account(id, email, stored_phone, password_hash, status)}

      {:ok, _} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_account_by_email(email) when is_binary(email) do
    case Repo.query(
           """
           SELECT a.user_id::text, a.email, a.phone, a.password_hash, u.status::text
           FROM public.mithril_auth_accounts a
           JOIN public.users u ON u.id = a.user_id
           WHERE u.status::text = 'active'
             AND lower(coalesce(a.email, '')) = $1
           """,
           [email]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, stored_email, phone, password_hash, status]]}} ->
        {:ok, account(id, stored_email, phone, password_hash, status)}

      {:ok, _} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_account_by_email(_), do: {:error, :not_found}

  defp fetch_account_by_identity(provider, subject) do
    case Repo.query(
           """
           SELECT a.user_id::text, a.email, a.phone, a.password_hash, u.status::text
           FROM public.mithril_auth_identities i
           JOIN public.mithril_auth_accounts a ON a.user_id = i.user_id
           JOIN public.users u ON u.id = a.user_id
           WHERE i.provider = $1
             AND i.provider_subject = $2
             AND u.status::text = 'active'
           """,
           [provider, subject]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, email, phone, password_hash, status]]}} ->
        {:ok, account(id, email, phone, password_hash, status)}

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

  defp ensure_sms_configured(phone) do
    if SMS.deliverable?(phone), do: :ok, else: {:error, :sms_not_configured}
  end

  defp ensure_otp_account(_phone, true), do: :ok

  defp ensure_otp_account(phone, false) do
    case fetch_account_by_phone(phone) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :user_not_found}
      other -> other
    end
  end

  defp create_otp(phone, request_ip) do
    lock_keys = ["otp-phone:#{phone}"] ++ maybe_lock_key("otp-ip", request_ip)

    Repo.transaction(fn ->
      with :ok <- lock_transaction_keys(lock_keys),
           :ok <- maybe_enforce_otp_rate_limit(phone, request_ip),
           {:ok, code} <- persist_otp(phone, request_ip) do
        code
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, code} -> {:ok, code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_enforce_otp_rate_limit(phone, request_ip) do
    if TestPhones.configured?(phone) do
      :ok
    else
      ensure_otp_not_rate_limited(phone, request_ip)
    end
  end

  defp ensure_otp_not_rate_limited(phone, request_ip) do
    case Repo.query(
           """
           SELECT
             EXISTS (
               SELECT 1
               FROM public.mithril_auth_otps
               WHERE phone = $1
                 AND inserted_at > now() - ($2 * interval '1 second')
             ) AS resend_limited,
             (
               SELECT count(*)
               FROM public.mithril_auth_otps
               WHERE phone = $1
                 AND inserted_at > now() - interval '1 hour'
             ) >= $3 AS phone_limited,
             CASE
               WHEN $4::text IS NULL OR $4::text = '' THEN false
               ELSE (
                 SELECT count(*)
                 FROM public.mithril_auth_otps
                 WHERE request_ip = $4::text
                   AND inserted_at > now() - interval '1 hour'
               ) >= $5
             END AS ip_limited
           """,
           [
             phone,
             @otp_resend_seconds,
             @otp_phone_hourly_limit,
             request_ip,
             @otp_ip_hourly_limit
           ]
         ) do
      {:ok, %{rows: [[false, false, false]]}} -> :ok
      {:ok, %{rows: [[_, _, _]]}} -> {:error, :otp_rate_limited}
      {:error, error} -> database_error(error)
    end
  end

  defp persist_otp(phone, request_ip) do
    code = TestPhones.lookup(phone) || otp_code()
    hash = hash_refresh(code)
    expires_at = DateTime.add(DateTime.utc_now(), @otp_ttl_seconds, :second)

    with {:ok, _} <-
           Repo.query(
             """
             UPDATE public.mithril_auth_otps
             SET consumed_at = now()
             WHERE phone = $1 AND consumed_at IS NULL
             """,
             [phone]
           ),
         {:ok, _} <-
           Repo.query(
             """
             INSERT INTO public.mithril_auth_otps (phone, code_hash, expires_at, request_ip)
             VALUES ($1, $2, $3, $4)
             """,
             [phone, hash, expires_at, request_ip]
           ) do
      {:ok, code}
    else
      {:error, error} -> database_error(error)
    end
  end

  defp consume_otp(phone, token) do
    token = String.trim(token)

    Repo.transaction(fn ->
      case Repo.query(
             """
             SELECT id::text, code_hash, attempt_count, expires_at
             FROM public.mithril_auth_otps
             WHERE phone = $1
               AND consumed_at IS NULL
             ORDER BY inserted_at DESC
             LIMIT 1
             FOR UPDATE
             """,
             [phone]
           ) do
        {:ok, %{num_rows: 1, rows: [[id, code_hash, attempts, expires_at]]}} ->
          consume_locked_otp(id, code_hash, attempts, expires_at, phone, token)

        {:ok, _} ->
          {:error, :invalid_otp}

        {:error, error} ->
          Repo.rollback({:database_error, error})
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, {:database_error, error}} -> database_error(error)
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_locked_otp(id, code_hash, attempts, expires_at, phone, token) do
    cond do
      expired?(expires_at) ->
        {:error, :otp_expired}

      attempts >= @otp_max_attempts ->
        {:error, :invalid_otp}

      not otp_matches?(token, code_hash) ->
        case Repo.query(
               "UPDATE public.mithril_auth_otps SET attempt_count = attempt_count + 1 WHERE id = $1::uuid",
               [dump_uuid(id)]
             ) do
          {:ok, _} -> {:error, :invalid_otp}
          {:error, error} -> Repo.rollback({:database_error, error})
        end

      true ->
        case Repo.query(
               "UPDATE public.mithril_auth_otps SET consumed_at = now() WHERE id = $1::uuid AND consumed_at IS NULL",
               [dump_uuid(id)]
             ) do
          {:ok, %{num_rows: 1}} ->
            case find_or_create_phone_account(phone) do
              {:ok, account} -> {:ok, account}
              {:error, reason} -> Repo.rollback(reason)
            end

          {:ok, _} ->
            {:error, :invalid_otp}

          {:error, error} ->
            Repo.rollback({:database_error, error})
        end
    end
  end

  defp find_or_create_phone_account(phone) do
    case fetch_account_by_phone(phone) do
      {:ok, account} ->
        maybe_set_phone(account, phone)

      {:error, :not_found} ->
        with {:ok, user_id} <- insert_user(%{phone: phone}),
             :ok <- insert_account(user_id, %{phone: phone}),
             :ok <- upsert_identity(user_id, %{provider: "phone", subject: phone, email: nil}) do
          fetch_account_by_id(user_id)
        end

      other ->
        other
    end
  end

  defp maybe_set_phone(%{phone: phone} = account, phone), do: {:ok, account}

  defp maybe_set_phone(account, phone) do
    case Repo.query(
           """
           UPDATE public.mithril_auth_accounts
           SET phone = $2, updated_at = now()
           WHERE user_id = $1::uuid AND phone IS NULL
           """,
           [dump_uuid(account.user_id), phone]
         ) do
      {:ok, _} -> {:ok, %{account | phone: phone}}
      {:error, error} -> database_error(error)
    end
  end

  defp verify_oauth("google", token), do: OAuth.verify_google(token)
  defp verify_oauth("facebook", token), do: OAuth.verify_facebook(token)
  defp verify_oauth(_, _), do: {:error, :invalid_provider}

  defp find_or_create_oauth_account(identity) do
    lock_keys =
      ["oauth:#{identity.provider}:#{identity.subject}"] ++ maybe_lock_key("auth-email", identity.email)

    Repo.transaction(fn ->
      with :ok <- lock_transaction_keys(lock_keys),
           {:ok, account} <- resolve_oauth_account(identity),
           :ok <- upsert_identity(account.user_id, identity) do
        account
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, account} ->
        {:ok, account}

      {:error, :oauth_identity_conflict} ->
        fetch_account_by_identity(identity.provider, identity.subject)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_oauth_account(identity) do
    case fetch_account_by_identity(identity.provider, identity.subject) do
      {:ok, account} ->
        {:ok, account}

      {:error, :not_found} ->
        case fetch_account_by_email(identity.email) do
          {:ok, account} ->
            {:ok, account}

          {:error, :not_found} ->
            with {:ok, user_id} <- insert_user(%{email: identity.email}),
                 :ok <- insert_account(user_id, %{email: identity.email}) do
              fetch_account_by_id(user_id)
            end

          other ->
            other
        end

      other ->
        other
    end
  end

  defp upsert_identity(user_id, identity) do
    case Repo.query(
           """
           INSERT INTO public.mithril_auth_identities AS identities
             (user_id, provider, provider_subject, email)
           VALUES ($1::uuid, $2, $3, $4)
           ON CONFLICT (provider, provider_subject) DO UPDATE
           SET email = COALESCE(EXCLUDED.email, identities.email),
               updated_at = now()
           WHERE identities.user_id = EXCLUDED.user_id
           RETURNING identities.user_id::text
           """,
           [
             dump_uuid(user_id),
             identity.provider,
             identity.subject,
             identity[:email] || identity.email
           ]
         ) do
      {:ok, %{num_rows: 1, rows: [[^user_id]]}} -> :ok
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :oauth_identity_conflict}
      {:error, error} -> database_error(error)
    end
  end

  defp insert_user_and_account(attrs) do
    with {:ok, user_id} <- insert_user(attrs),
         :ok <- insert_account(user_id, attrs) do
      {:ok, user_id}
    end
  end

  defp insert_user(attrs) do
    user_id = Ecto.UUID.generate()
    email = attrs[:email]
    phone = attrs[:phone]
    password_hash = attrs[:password_hash]
    public_password_hash = password_hash || ""

    Repo.transaction(fn ->
      with {:ok, _} <-
             Repo.query(
               """
               INSERT INTO auth.users (id, email, phone, encrypted_password, created_at, updated_at)
               VALUES ($1::uuid, $2, $3, $4, now(), now())
               """,
               [dump_uuid(user_id), email, phone, password_hash]
             ),
           {:ok, _} <-
             Repo.query(
               """
               INSERT INTO public.users (id, email, phone, password_hash, status, created_at, updated_at)
               VALUES ($1::uuid, $2, $3, $4, 'active', now(), now())
               ON CONFLICT (id) DO UPDATE
               SET email = COALESCE(EXCLUDED.email, public.users.email),
                   phone = COALESCE(EXCLUDED.phone, public.users.phone),
                   password_hash = COALESCE(NULLIF(EXCLUDED.password_hash, ''), public.users.password_hash),
                   status = 'active',
                   updated_at = now()
               """,
               [dump_uuid(user_id), email, phone, public_password_hash]
             ) do
        user_id
      else
        {:error, %{postgres: %{code: :unique_violation}}} ->
          Repo.rollback(taken_error(email))

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, registered_user_id} -> {:ok, registered_user_id}
      {:error, :email_taken} -> {:error, :email_taken}
      {:error, :phone_taken} -> {:error, :phone_taken}
      {:error, error} -> database_error(error)
    end
  end

  defp insert_account(user_id, attrs) do
    email = attrs[:email]
    phone = attrs[:phone]
    password_hash = attrs[:password_hash]

    case Repo.query(
           """
           INSERT INTO public.mithril_auth_accounts (user_id, email, phone, password_hash)
           VALUES ($1::uuid, $2, $3, $4)
           """,
           [dump_uuid(user_id), email, phone, password_hash]
         ) do
      {:ok, _} -> :ok
      {:error, %{postgres: %{code: :unique_violation}}} -> {:error, taken_error(email)}
      {:error, error} -> database_error(error)
    end
  end

  defp update_password_and_revoke_sessions(user_id, password_hash) do
    Repo.transaction(fn ->
      with {:ok, _} <-
             Repo.query(
               """
               UPDATE public.mithril_auth_accounts
               SET password_hash = $2, updated_at = now()
               WHERE user_id = $1::uuid
               """,
               [dump_uuid(user_id), password_hash]
             ),
           {:ok, _} <-
             Repo.query(
               """
               UPDATE public.users
               SET password_hash = $2, updated_at = now()
               WHERE id = $1::uuid
               """,
               [dump_uuid(user_id), password_hash]
             ),
           {:ok, _} <-
             Repo.query(
               """
               UPDATE auth.users
               SET encrypted_password = $2, updated_at = now()
               WHERE id = $1::uuid
               """,
               [dump_uuid(user_id), password_hash]
             ),
           {:ok, _} <-
             Repo.query(
               """
               UPDATE public.mithril_refresh_tokens
               SET revoked_at = now()
               WHERE user_id = $1::uuid
                 AND revoked_at IS NULL
               """,
               [dump_uuid(user_id)]
             ) do
        :ok
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp lock_transaction_keys(keys) do
    keys
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [key]) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, database_error(error)}
      end
    end)
  end

  defp maybe_lock_key(_prefix, value) when value in [nil, ""], do: []
  defp maybe_lock_key(prefix, value), do: ["#{prefix}:#{value}"]

  defp taken_error(email) when is_binary(email), do: :email_taken
  defp taken_error(_), do: :phone_taken

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

  defp normalize_login(value), do: value |> String.trim() |> String.downcase()

  defp normalize_phone(value) do
    case Phone.normalize(value) do
      {:ok, phone} -> {:ok, phone}
      :error -> {:error, :invalid_phone}
    end
  end

  defp normalize_request_ip(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      ip -> ip
    end
  end

  defp normalize_request_ip(_), do: nil

  defp session_user(account) do
    phone = account.phone || e164_if_phone(account.email)
    email = if phone && account.email == phone, do: nil, else: account.email

    %{id: account.user_id, email: email, phone: phone}
  end

  defp e164_if_phone(value) do
    case Phone.normalize(value) do
      {:ok, phone} -> phone
      :error -> nil
    end
  end

  defp account(user_id, email, phone, password_hash, status) do
    %{user_id: user_id, email: email, phone: phone, password_hash: password_hash, status: status}
  end

  defp dump_uuid(user_id) do
    case Ecto.UUID.dump(user_id) do
      {:ok, dumped} -> dumped
      :error -> user_id
    end
  end

  defp hash_refresh(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp otp_code do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp otp_matches?(token, hash), do: hash_refresh(token) == hash

  defp expired?(%DateTime{} = expires_at) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  defp expired?(expires_at) do
    case DateTime.from_naive(expires_at, "Etc/UTC") do
      {:ok, datetime} -> expired?(datetime)
      {:error, _} -> true
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "yes"], do: true
  defp truthy?(_), do: false

  defp database_error(error) do
    Logger.error("Auth database operation failed: #{Exception.message(error)}")
    {:error, :database_unavailable}
  end
end
