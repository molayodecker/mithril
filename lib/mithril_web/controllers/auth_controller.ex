defmodule MithrilWeb.AuthController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Auth

  def login(conn, params) do
    email = Map.get(params, "email") || Map.get(params, "phone") || Map.get(params, "login")
    password = Map.get(params, "password")

    respond(conn, Auth.login(email, password))
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
  defp error_response(:email_taken), do: {409, "email_taken"}
  defp error_response(:invalid_email), do: {422, "invalid_email"}
  defp error_response(:weak_password), do: {422, "weak_password"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
