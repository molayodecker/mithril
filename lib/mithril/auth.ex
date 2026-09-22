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
    with {:ok, account} <- fetch_account_by_id(user_id),
         {:ok, roles} <- fetch_roles(user_id),
         {:ok, cleaner_state} <- fetch_cleaner_state(user_id) do
      user =
        account
        |> session_user()
        |> Map.put(:status, account.status)
        |> Map.put(:admin, "admin" in roles)
        |> Map.put(:reviewer, "reviewer" in roles)
        |> Map.put(:roles, roles)
        |> Map.put(:cleanerVerified, cleaner_state.verified)
        |> Map.put(:cleanerStatus, cleaner_state.status)

      {:ok, user}
    end
  end

  @profile_roles MapSet.new(["customer", "cleaner"])

  def update_profile(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, _account} <- fetch_account_by_id(user_id),
         {:ok, fields} <- normalize_profile_attrs(attrs),
         :ok <- persist_profile(user_id, fields) do
      me(user_id)
    end
  end

  def update_profile(_, _), do: {:error, :invalid_profile}

  def admin?(user_id) when is_binary(user_id), do: has_role?(user_id, "admin")

  def reviewer?(user_id) when is_binary(user_id), do: has_role?(user_id, "reviewer")

  def staff?(user_id) when is_binary(user_id), do: admin?(user_id) or reviewer?(user_id)

  def staff_uuid?(uid) when is_binary(uid) do
    case Ecto.UUID.cast(uid) do
      {:ok, user_id} -> staff?(user_id)
      :error -> false
    end
  end

  defp has_role?(user_id, role) when is_binary(user_id) and is_binary(role) do
    case Repo.query(
           """
           SELECT EXISTS (
             SELECT 1
             FROM public.user_roles
             WHERE user_id = $1::uuid
               AND role_id = $2
           )
           """,
           [dump_uuid(user_id), role]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _other -> false
    end
  end

  defp fetch_roles(user_id) do
    case Repo.query(
           """
           SELECT role_id::text
           FROM public.user_roles
           WHERE user_id = $1::uuid
           ORDER BY role_id
           """,
           [dump_uuid(user_id)]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp fetch_cleaner_state(user_id) do
    case Repo.query(
           """
           SELECT COALESCE(verified, false), status::text
           FROM public.cleaner_data
           WHERE user_id = $1::uuid
           LIMIT 1
           """,
           [dump_uuid(user_id)]
         ) do
      {:ok, %{rows: [[verified, status]]}} -> {:ok, %{verified: verified == true, status: status}}
      {:ok, %{rows: []}} -> {:ok, %{verified: false, status: nil}}
      {:error, error} -> database_error(error)
    end
  end

  def provision_admin(email, password) when is_binary(email) and is_binary(password) do
    provision_admin(%{email: email, password: password})
  end

  def provision_admin(_, _), do: {:error, :invalid_email}

  def provision_admin(attrs) when is_map(attrs) do
    email = blank_to_nil(Map.get(attrs, :email) || Map.get(attrs, "email"))
    phone = blank_to_nil(Map.get(attrs, :phone) || Map.get(attrs, "phone"))
    password = blank_to_nil(Map.get(attrs, :password) || Map.get(attrs, "password"))

    with {:ok, email, phone} <- normalize_admin_identifiers(email, phone),
         :ok <- validate_admin_credentials(email, phone, password) do
      password_hash = if password, do: Bcrypt.hash_pwd_salt(password)

      case fetch_or_link_admin_account(email, phone) do
        {:ok, account} ->
          with :ok <- sync_admin_contact(account.user_id, email, phone),
               :ok <- maybe_upsert_phone_identity(account.user_id, phone) do
            finalize_admin(account.user_id, password_hash)
          end

        {:error, :not_found} ->
          with {:ok, user_id} <-
                 insert_user_and_account(%{
                   email: email,
                   phone: phone,
                   password_hash: password_hash
                 }),
               :ok <- maybe_upsert_phone_identity(user_id, phone) do
            finalize_admin(user_id, nil)
          end

        other ->
          other
      end
    end
  end

  def grant_staff(attrs) when is_map(attrs) do
    role = to_string(Map.get(attrs, :role) || Map.get(attrs, "role") || "admin")
    email = blank_to_nil(Map.get(attrs, :email) || Map.get(attrs, "email"))
    phone = blank_to_nil(Map.get(attrs, :phone) || Map.get(attrs, "phone"))

    with {:ok, role} <- staff_role(role),
         {:ok, user} <- find_staff_user(email, phone),
         :ok <- insert_staff_role(user.id, role) do
      {:ok,
       %{
         id: user.id,
         email: user.email,
         phone: user.phone,
         role: role,
         admin: admin?(user.id),
         reviewer: reviewer?(user.id)
       }}
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
             AND (
               lower(coalesce(a.email, '')) = $1
               OR lower(coalesce(u.email, '')) = $1
             )
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
      ["oauth:#{identity.provider}:#{identity.subject}"] ++
        maybe_lock_key("auth-email", identity.email)

    Repo.transaction(fn ->
      with :ok <- lock_transaction_keys(lock_keys),
           {:ok, account} <- resolve_oauth_account(identity),
           :ok <- upsert_identity(account.user_id, identity),
           :ok <- seed_oauth_profile(account.user_id, identity) do
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
        resolve_oauth_account_by_email(identity)

      other ->
        other
    end
  end

  defp resolve_oauth_account_by_email(identity) do
    case fetch_account_by_email(identity.email) do
      {:ok, account} ->
        {:ok, account}

      {:error, :not_found} ->
        case link_existing_user_by_email(identity.email) do
          {:ok, account} ->
            {:ok, account}

          {:error, :not_found} ->
            create_oauth_user(identity)

          other ->
            other
        end

      other ->
        other
    end
  end

  defp create_oauth_user(identity) do
    with {:ok, user_id} <- insert_user(%{email: identity.email}),
         :ok <- insert_account(user_id, %{email: identity.email}) do
      fetch_account_by_id(user_id)
    else
      {:error, :email_taken} ->
        case link_existing_user_by_email(identity.email) do
          {:ok, account} -> {:ok, account}
          {:error, :not_found} -> {:error, :email_taken}
          other -> other
        end

      other ->
        other
    end
  end

  defp link_existing_user_by_email(email) when is_binary(email) and email != "" do
    case fetch_public_user_for_admin(email, nil) do
      {:ok, user_id, stored_email, stored_phone, password_hash, status} ->
        attrs = %{
          email: stored_email || email,
          phone: stored_phone,
          password_hash: password_hash
        }

        case insert_account(user_id, attrs) do
          :ok -> {:ok, account(user_id, attrs.email, stored_phone, password_hash, status)}
          {:error, :email_taken} -> fetch_account_by_email(email)
          other -> other
        end

      other ->
        other
    end
  end

  defp link_existing_user_by_email(_), do: {:error, :not_found}

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

  defp finalize_admin(user_id, nil) do
    with :ok <- grant_admin(user_id),
         {:ok, account} <- fetch_account_by_id(user_id) do
      {:ok, Map.put(session_user(account), :admin, true)}
    end
  end

  defp finalize_admin(user_id, password_hash) do
    with :ok <- update_password_and_revoke_sessions(user_id, password_hash) do
      finalize_admin(user_id, nil)
    end
  end

  defp grant_admin(user_id) do
    case Repo.query(
           """
           INSERT INTO public.user_roles (user_id, role_id)
           SELECT $1::uuid, 'admin'
           WHERE NOT EXISTS (
             SELECT 1
             FROM public.user_roles
             WHERE user_id = $1::uuid
               AND role_id = 'admin'
           )
           """,
           [dump_uuid(user_id)]
         ) do
      {:ok, _} -> :ok
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

  defp normalize_admin_identifiers(email, phone) do
    email = if email, do: normalize_login(email)

    with :ok <- if(email, do: validate_email(email), else: :ok),
         {:ok, phone} <- normalize_optional_phone(phone) do
      if email || phone do
        {:ok, email, phone}
      else
        {:error, :invalid_email}
      end
    end
  end

  defp normalize_optional_phone(nil), do: {:ok, nil}

  defp normalize_optional_phone(phone) do
    case normalize_phone(phone) do
      {:ok, value} -> {:ok, value}
      other -> other
    end
  end

  defp validate_admin_credentials(email, nil, password)
       when is_binary(email) and (not is_binary(password) or password == "") do
    {:error, :weak_password}
  end

  defp validate_admin_credentials(_email, _phone, password) when is_binary(password) do
    validate_password(password)
  end

  defp validate_admin_credentials(_email, phone, _password) when is_binary(phone), do: :ok
  defp validate_admin_credentials(_, _, _), do: {:error, :invalid_email}

  defp fetch_or_link_admin_account(email, phone) do
    case fetch_admin_account(email, phone) do
      {:ok, account} ->
        {:ok, account}

      {:error, :not_found} ->
        case fetch_public_user_for_admin(email, phone) do
          {:ok, user_id, stored_email, stored_phone, password_hash, status} ->
            with :ok <-
                   insert_account(user_id, %{
                     email: email || stored_email,
                     phone: phone || stored_phone,
                     password_hash: password_hash
                   }) do
              {:ok,
               account(
                 user_id,
                 email || stored_email,
                 phone || stored_phone,
                 password_hash,
                 status
               )}
            end

          other ->
            other
        end

      other ->
        other
    end
  end

  defp fetch_admin_account(email, phone) do
    case Repo.query(
           """
           SELECT a.user_id::text, a.email, a.phone, a.password_hash, u.status::text
           FROM public.mithril_auth_accounts a
           JOIN public.users u ON u.id = a.user_id
           WHERE u.status::text = 'active'
             AND (
               ($1::text IS NOT NULL AND lower(coalesce(a.email, '')) = $1)
               OR (
                 $2::text IS NOT NULL
                 AND (
                   a.phone = $2
                   OR lower(btrim(coalesce(u.phone, ''))) = $2
                 )
               )
             )
           """,
           [email, phone]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, stored_email, stored_phone, password_hash, status]]}} ->
        {:ok, account(id, stored_email, stored_phone, password_hash, status)}

      {:ok, %{num_rows: 0}} ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :account_conflict}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_public_user_for_admin(email, phone) do
    case Repo.query(
           """
           SELECT u.id::text,
                  coalesce(u.email, au.email),
                  coalesce(u.phone, au.phone),
                  u.password_hash,
                  u.status::text
           FROM public.users u
           JOIN auth.users au ON au.id = u.id
           WHERE u.status::text = 'active'
             AND (
               ($1::text IS NOT NULL AND (
                 lower(coalesce(u.email, '')) = $1
                 OR lower(coalesce(au.email, '')) = $1
               ))
               OR (
                 $2::text IS NOT NULL
                 AND (
                   u.phone = $2
                   OR au.phone = $2
                   OR lower(btrim(coalesce(u.phone, ''))) = $2
                   OR lower(btrim(coalesce(au.phone, ''))) = $2
                 )
               )
             )
           """,
           [email, phone]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, stored_email, stored_phone, password_hash, status]]}} ->
        {:ok, id, stored_email, stored_phone, password_hash, status}

      {:ok, %{num_rows: 0}} ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :account_conflict}

      {:error, error} ->
        database_error(error)
    end
  end

  defp sync_admin_contact(user_id, email, phone) do
    Repo.transaction(fn ->
      with :ok <-
             maybe_update_admin_column(
               "public.mithril_auth_accounts",
               "user_id",
               user_id,
               email,
               phone
             ),
           :ok <- maybe_update_admin_column("public.users", "id", user_id, email, phone),
           :ok <- maybe_update_admin_auth_user(user_id, email, phone) do
        :ok
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, %{postgres: %{code: :unique_violation}}} -> {:error, taken_error(email)}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp maybe_update_admin_column(table, id_column, user_id, email, phone) do
    case Repo.query(
           """
           UPDATE #{table}
           SET email = COALESCE($2, email),
               phone = COALESCE($3, phone),
               updated_at = now()
           WHERE #{id_column} = $1::uuid
           """,
           [dump_uuid(user_id), email, phone]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_update_admin_auth_user(user_id, email, phone) do
    case Repo.query(
           """
           UPDATE auth.users
           SET email = COALESCE($2, email),
               phone = COALESCE($3, phone),
               updated_at = now()
           WHERE id = $1::uuid
           """,
           [dump_uuid(user_id), email, phone]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_upsert_phone_identity(_user_id, nil), do: :ok

  defp maybe_upsert_phone_identity(user_id, phone) do
    upsert_identity(user_id, %{provider: "phone", subject: phone, email: nil})
  end

  defp staff_role(role) when role in ~w(admin reviewer), do: {:ok, role}
  defp staff_role(_), do: {:error, :invalid_role}

  defp find_staff_user(email, phone) do
    cond do
      is_binary(phone) ->
        with {:ok, phone} <- normalize_phone(phone),
             {:ok, user} <- fetch_user_by_phone(phone) do
          {:ok, user}
        end

      is_binary(email) ->
        fetch_user_by_email(normalize_login(email))

      true ->
        {:error, :invalid_request}
    end
  end

  defp fetch_user_by_phone(phone) do
    case Repo.query(
           """
           SELECT id::text, email, phone
           FROM public.users
           WHERE phone = $1
              OR lower(coalesce(email, '')) = $1
           LIMIT 1
           """,
           [phone]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, email, stored_phone]]}} ->
        {:ok, %{id: id, email: email, phone: stored_phone}}

      {:ok, _} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_user_by_email(email) do
    case Repo.query(
           """
           SELECT id::text, email, phone
           FROM public.users
           WHERE lower(coalesce(email, '')) = $1
           LIMIT 1
           """,
           [email]
         ) do
      {:ok, %{num_rows: 1, rows: [[id, stored_email, phone]]}} ->
        {:ok, %{id: id, email: stored_email, phone: phone}}

      {:ok, _} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp insert_staff_role(user_id, role) do
    case Repo.query(
           """
           INSERT INTO public.user_roles (user_id, role_id)
           SELECT $1::uuid, $2
           WHERE NOT EXISTS (
             SELECT 1 FROM public.user_roles
             WHERE user_id = $1::uuid AND role_id = $2
           )
           """,
           [dump_uuid(user_id), role]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_), do: nil

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

    %{
      id: account.user_id,
      email: email,
      phone: phone,
      name: profile_display_name(account.user_id)
    }
  end

  defp profile_display_name(user_id) do
    case Repo.query(
           """
           SELECT COALESCE(
             NULLIF(btrim(fullname), ''),
             NULLIF(btrim(concat_ws(' ', firstname, lastname)), '')
           )
           FROM public.profiles
           WHERE id = $1::uuid
           LIMIT 1
           """,
           [dump_uuid(user_id)]
         ) do
      {:ok, %{rows: [[name]]}} when is_binary(name) and name != "" -> name
      _other -> nil
    end
  end

  defp seed_oauth_profile(user_id, identity) do
    {first_name, last_name, fullname} = oauth_name_parts(identity)
    avatar_url = blank_to_nil(identity[:picture])

    if is_nil(first_name) and is_nil(avatar_url) do
      :ok
    else
      case Repo.query(
             """
             INSERT INTO public.profiles (
               id, user_id, firstname, lastname, fullname, avatar_url
             )
             VALUES ($1::uuid, $1::uuid, $2, $3, $4, $5)
             ON CONFLICT (id) DO UPDATE
             SET firstname = COALESCE(NULLIF(btrim(public.profiles.firstname), ''), EXCLUDED.firstname),
                 lastname = COALESCE(NULLIF(btrim(public.profiles.lastname), ''), EXCLUDED.lastname),
                 fullname = COALESCE(NULLIF(btrim(public.profiles.fullname), ''), EXCLUDED.fullname),
                 avatar_url = COALESCE(NULLIF(btrim(public.profiles.avatar_url), ''), EXCLUDED.avatar_url)
             """,
             [dump_uuid(user_id), first_name, last_name, fullname, avatar_url]
           ) do
        {:ok, _} -> :ok
        {:error, error} -> unique_or_database_error(error)
      end
    end
  end

  defp oauth_name_parts(identity) do
    given = blank_to_nil(identity[:given_name])
    family = blank_to_nil(identity[:family_name]) || ""
    full = blank_to_nil(identity[:name])

    cond do
      is_binary(given) ->
        {given, family, Enum.join(Enum.reject([given, family], &(&1 == "")), " ")}

      is_binary(full) ->
        case String.split(full, ~r/\s+/, parts: 2) do
          [first, last] -> {first, last, full}
          [first] -> {first, "", full}
          _ -> {nil, nil, nil}
        end

      true ->
        {nil, nil, nil}
    end
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

  defp normalize_profile_attrs(attrs) do
    first_name = profile_string(attrs, ["first_name", "firstname", :first_name, :firstname])
    last_name = profile_string(attrs, ["last_name", "lastname", :last_name, :lastname])
    phone = profile_string(attrs, ["phone", :phone])
    email = profile_optional_string(attrs, ["email", :email])
    avatar_url = profile_optional_string(attrs, ["avatar_url", :avatar_url])
    address = profile_optional_string(attrs, ["address", :address])
    location_wkt = profile_optional_string(attrs, ["location_wkt", :location_wkt])
    write_email? = profile_has_key?(attrs, ["email", :email])
    roles = profile_roles(attrs)

    cond do
      is_nil(first_name) ->
        {:error, :invalid_profile}

      true ->
        with {:ok, phone} <- normalize_phone(phone || "") do
          {:ok,
           %{
             first_name: first_name,
             last_name: last_name || "",
             phone: phone,
             email: email,
             write_email?: write_email?,
             avatar_url: avatar_url,
             address: address,
             location_wkt: location_wkt,
             roles: roles
           }}
        end
    end
  end

  defp persist_profile(user_id, fields) do
    Repo.transaction(fn ->
      with :ok <- update_public_user_profile(user_id, fields),
           :ok <- update_auth_account_profile(user_id, fields),
           :ok <- update_auth_user_profile(user_id, fields),
           :ok <- upsert_public_profile(user_id, fields),
           :ok <- ensure_profile_roles(user_id, fields.roles) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp update_public_user_profile(user_id, fields) do
    sql =
      if fields.write_email? do
        """
        UPDATE public.users
        SET phone = $2,
            email = $3,
            updated_at = now()
        WHERE id = $1::uuid
        """
      else
        """
        UPDATE public.users
        SET phone = $2,
            updated_at = now()
        WHERE id = $1::uuid
        """
      end

    params =
      if fields.write_email? do
        [dump_uuid(user_id), fields.phone, fields.email]
      else
        [dump_uuid(user_id), fields.phone]
      end

    case Repo.query(sql, params) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :user_not_found}
      {:error, error} -> unique_or_database_error(error)
    end
  end

  defp update_auth_account_profile(user_id, fields) do
    sql =
      if fields.write_email? do
        """
        UPDATE public.mithril_auth_accounts
        SET phone = $2,
            email = $3,
            updated_at = now()
        WHERE user_id = $1::uuid
        """
      else
        """
        UPDATE public.mithril_auth_accounts
        SET phone = $2,
            updated_at = now()
        WHERE user_id = $1::uuid
        """
      end

    params =
      if fields.write_email? do
        [dump_uuid(user_id), fields.phone, fields.email]
      else
        [dump_uuid(user_id), fields.phone]
      end

    case Repo.query(sql, params) do
      {:ok, %{num_rows: rows}} when rows in [0, 1] -> :ok
      {:error, error} -> unique_or_database_error(error)
    end
  end

  defp update_auth_user_profile(user_id, fields) do
    sql =
      if fields.write_email? do
        """
        UPDATE auth.users
        SET phone = $2,
            email = COALESCE($3, email),
            updated_at = now()
        WHERE id = $1::uuid
        """
      else
        """
        UPDATE auth.users
        SET phone = $2,
            updated_at = now()
        WHERE id = $1::uuid
        """
      end

    params =
      if fields.write_email? do
        [dump_uuid(user_id), fields.phone, fields.email]
      else
        [dump_uuid(user_id), fields.phone]
      end

    case Repo.query(sql, params) do
      {:ok, _} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> :ok
      {:error, error} -> unique_or_database_error(error)
    end
  end

  defp upsert_public_profile(user_id, fields) do
    fullname =
      [fields.first_name, fields.last_name]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> case do
        "" -> fields.first_name
        name -> name
      end

    case Repo.query(
           """
           INSERT INTO public.profiles (
             id, user_id, firstname, lastname, fullname, avatar_url, address, location_wkt
           )
           VALUES ($1::uuid, $1::uuid, $2, $3, $4, $5, $6, $7)
           ON CONFLICT (id) DO UPDATE
           SET firstname = EXCLUDED.firstname,
               lastname = EXCLUDED.lastname,
               fullname = EXCLUDED.fullname,
               avatar_url = EXCLUDED.avatar_url,
               address = EXCLUDED.address,
               location_wkt = EXCLUDED.location_wkt
           """,
           [
             dump_uuid(user_id),
             fields.first_name,
             fields.last_name,
             fullname,
             fields.avatar_url,
             fields.address,
             fields.location_wkt
           ]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> unique_or_database_error(error)
    end
  end

  defp ensure_profile_roles(_user_id, []), do: :ok

  defp ensure_profile_roles(user_id, roles) do
    Enum.reduce_while(roles, :ok, fn role, :ok ->
      case Repo.query(
             """
             INSERT INTO public.user_roles (user_id, role_id)
             SELECT $1::uuid, $2
             WHERE NOT EXISTS (
               SELECT 1
               FROM public.user_roles
               WHERE user_id = $1::uuid
                 AND role_id = $2
             )
             """,
             [dump_uuid(user_id), role]
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, unique_or_database_error(error)}
      end
    end)
  end

  defp unique_or_database_error(error) do
    postgres = Map.get(error, :postgres) || %{}
    constraint = postgres[:constraint] || ""
    message = postgres[:message] || Exception.message(error)
    haystack = String.downcase("#{constraint} #{message}")

    cond do
      postgres[:code] != :unique_violation ->
        database_error(error)

      String.contains?(haystack, "email") ->
        {:error, :email_taken}

      String.contains?(haystack, "phone") ->
        {:error, :phone_taken}

      true ->
        {:error, :email_taken}
    end
  end

  defp profile_string(attrs, keys) do
    case profile_optional_string(attrs, keys) do
      nil -> nil
      value -> value
    end
  end

  defp profile_optional_string(attrs, keys) do
    keys
    |> Enum.find_value(&Map.get(attrs, &1))
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp profile_has_key?(attrs, keys) do
    Enum.any?(keys, &Map.has_key?(attrs, &1))
  end

  defp profile_roles(attrs) do
    raw = Map.get(attrs, "roles") || Map.get(attrs, :roles) || []

    raw
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&MapSet.member?(@profile_roles, &1))
    |> Enum.uniq()
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
