defmodule Mithril.Auth.SignupEmail do
  @moduledoc false

  require Logger

  alias Mithril.Notifications.Outbound
  alias Mithril.Repo

  @ttl_seconds 86_400

  def deliver(%{user_id: user_id, email: email}) when is_binary(user_id) and is_binary(email) do
    email = String.trim(email)

    if email == "" or String.contains?(email, "@") == false do
      :ok
    else
      name = email |> String.split("@") |> hd()
      send_welcome(email, name)
      send_verification(user_id, email, name)
      :ok
    end
  end

  def deliver(_account), do: :ok

  def confirm(token) when is_binary(token) do
    hash = hash_token(String.trim(token))

    with {:ok, %{rows: [[user_id]]}} <- claim_token(hash),
         {:ok, _} <- mark_email_verified(user_id) do
      :ok
    else
      _ -> :error
    end
  end

  def confirm(_token), do: :error

  def confirmed_page do
    """
    <!doctype html>
    <html><body>
    <h1>Email verified</h1>
    <p>Your Instaclean email address is verified. You can return to the app.</p>
    </body></html>
    """
  end

  def invalid_page do
    """
    <!doctype html>
    <html><body>
    <h1>This link is not valid</h1>
    <p>The verification link is invalid or has expired. Sign in and request a new one if you still need to verify your email.</p>
    </body></html>
    """
  end

  defp send_welcome(email, name) do
    Outbound.deliver(%{
      "template" => "new_user_created",
      "channel" => "email",
      "email" => email,
      "variables" => %{"name" => name}
    })
  end

  defp send_verification(user_id, email, name) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    case store_token(user_id, hash_token(token)) do
      :ok ->
        Outbound.deliver(%{
          "template" => "signup_verification",
          "channel" => "email",
          "email" => email,
          "variables" => %{"name" => name, "confirmationUrl" => confirm_url(token)}
        })

      :error ->
        Logger.warning("signup verification email skipped because the token could not be stored")
    end
  end

  defp store_token(user_id, hash) do
    case Repo.query(
           """
           INSERT INTO public.mithril_email_verifications (user_id, token_hash, expires_at)
           VALUES ($1::uuid, $2, now() + ($3 * interval '1 second'))
           """,
           [Ecto.UUID.dump!(user_id), hash, @ttl_seconds]
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("signup verification token insert failed: #{error.postgres.code}")
        :error
    end
  rescue
    error ->
      Logger.warning("signup verification token insert failed: #{inspect(error.__struct__)}")
      :error
  end

  defp claim_token(hash) do
    Repo.query(
      """
      UPDATE public.mithril_email_verifications
      SET used_at = now()
      WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now()
      RETURNING user_id::text
      """,
      [hash]
    )
  end

  defp mark_email_verified(user_id) do
    Repo.query(
      """
      UPDATE public.users
      SET contact_email_verified_at = now(), updated_at = now()
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(user_id)]
    )
  end

  defp confirm_url(token) do
    endpoint = Application.get_env(:mithril, MithrilWeb.Endpoint, [])
    url = Keyword.get(endpoint, :url, [])
    host = Keyword.get(url, :host) || "api.tryinstaclean.com"
    scheme = Keyword.get(url, :scheme, "https")
    port = Keyword.get(url, :port)

    origin =
      if port in [nil, 80, 443], do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"

    origin <> "/auth/confirm-email?token=" <> URI.encode_www_form(token)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
