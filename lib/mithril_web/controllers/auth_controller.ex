defmodule MithrilWeb.AuthController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Auth

  def methods(conn, _params) do
    json(conn, %{methods: Auth.methods()})
  end

  def login(conn, params) do
    email = Map.get(params, "email") || Map.get(params, "phone") || Map.get(params, "login")
    password = Map.get(params, "password")

    respond(conn, Auth.login(email, password))
  end

  def request_otp(conn, params) do
    opts = Map.put(params, "request_ip", request_ip(conn))
    respond(conn, Auth.request_otp(Map.get(params, "phone"), opts))
  end

  def verify_otp(conn, params) do
    respond(
      conn,
      Auth.verify_otp(
        Map.get(params, "phone"),
        Map.get(params, "token") || Map.get(params, "code")
      )
    )
  end

  def oauth(conn, %{"provider" => provider} = params) do
    token =
      Map.get(params, "id_token") ||
        Map.get(params, "access_token") ||
        Map.get(params, "token")

    respond(conn, Auth.oauth(provider, token))
  end

  def refresh(conn, params) do
    respond(conn, Auth.refresh(Map.get(params, "refresh_token")))
  end

  def logout(conn, params) do
    :ok = Auth.logout(Map.get(params, "refresh_token"))
    json(conn, %{ok: true})
  end

  def me(conn, _params) do
    respond(conn, Auth.me(conn.assigns.instaclean_user_id), fn user -> %{user: user} end)
  end

  def set_password(conn, params) do
    result =
      Auth.set_password(
        conn.assigns.instaclean_user_id,
        Map.get(params, "password"),
        Map.get(params, "current_password")
      )

    respond(conn, result, fn _ok -> %{ok: true} end)
  end

  def register(conn, params) do
    respond(conn, Auth.register(Map.get(params, "email"), Map.get(params, "password")))
  end

  defp request_ip(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip | _] when ip != "" -> String.trim(ip)
      _ -> remote_ip(conn.remote_ip)
    end
  end

  defp remote_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      chars -> to_string(chars)
    end
  end

  defp remote_ip(_), do: nil

  defp respond(conn, result, mapper \\ & &1)

  defp respond(conn, :ok, mapper) do
    json(conn, mapper.(:ok))
  end

  defp respond(conn, {:ok, value}, mapper) do
    json(conn, mapper.(value))
  end

  defp respond(conn, {:error, reason}, _mapper) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_credentials), do: {401, "invalid_credentials"}
  defp error_response(:password_not_set), do: {409, "password_not_set"}
  defp error_response(:invalid_refresh_token), do: {401, "invalid_refresh_token"}
  defp error_response(:current_password_required), do: {401, "current_password_required"}
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:user_not_found), do: {404, "user_not_found"}
  defp error_response(:email_taken), do: {409, "email_taken"}
  defp error_response(:phone_taken), do: {409, "phone_taken"}
  defp error_response(:invalid_email), do: {422, "invalid_email"}
  defp error_response(:invalid_phone), do: {422, "invalid_phone"}
  defp error_response(:weak_password), do: {422, "weak_password"}
  defp error_response(:invalid_otp), do: {401, "invalid_otp"}
  defp error_response(:otp_expired), do: {401, "otp_expired"}
  defp error_response(:otp_rate_limited), do: {429, "otp_rate_limited"}
  defp error_response(:sms_not_configured), do: {503, "sms_not_configured"}
  defp error_response(:sms_delivery_failed), do: {503, "sms_delivery_failed"}
  defp error_response(:oauth_not_configured), do: {503, "oauth_not_configured"}
  defp error_response(:invalid_oauth_token), do: {401, "invalid_oauth_token"}
  defp error_response(:oauth_identity_conflict), do: {409, "oauth_identity_conflict"}
  defp error_response(:invalid_provider), do: {422, "invalid_provider"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
