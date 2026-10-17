defmodule MithrilWeb.DirectAdminTeamController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminTeam
  alias MithrilWeb.Schemas.DirectAdminTeam.GrantRequest
  alias MithrilWeb.Schemas.DirectAdminTeam.ListResponse
  alias MithrilWeb.Schemas.DirectAdminTeam.Member
  alias MithrilWeb.Schemas.DirectAdminTeam.RevokeRequest
  alias MithrilWeb.Schemas.DirectAdminTeam.UpdateAccessRequest

  tags(["direct-admin-team"])

  operation(:index,
    operation_id: "direct.listAdminTeam",
    summary: "List staff members with admin or reviewer roles",
    responses: [ok: {"Team", "application/json", ListResponse}]
  )

  operation(:grant,
    operation_id: "direct.grantAdminTeamRole",
    summary: "Grant admin or reviewer to an existing user",
    request_body: {"Grant", "application/json", GrantRequest},
    responses: [ok: {"Updated member", "application/json", Member}]
  )

  operation(:revoke,
    operation_id: "direct.revokeAdminTeamRole",
    summary: "Remove admin or reviewer from a user",
    request_body: {"Revoke", "application/json", RevokeRequest},
    responses: [ok: {"Updated member", "application/json", Member}]
  )

  operation(:update_access,
    operation_id: "direct.updateAdminTeamAccess",
    summary: "Set staff roles and ops desk permissions for a user",
    request_body: {"Access", "application/json", UpdateAccessRequest},
    responses: [ok: {"Updated member", "application/json", Member}]
  )

  def index(conn, _params) do
    respond(conn, DirectAdminTeam.list(user_id(conn)))
  end

  def grant(conn, params) do
    respond(conn, DirectAdminTeam.grant(user_id(conn), params))
  end

  def revoke(conn, params) do
    respond(conn, DirectAdminTeam.revoke(user_id(conn), params))
  end

  def update_access(conn, params) do
    respond(conn, DirectAdminTeam.update_access(user_id(conn), params))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, {:ok, payload}) do
    json(conn, payload)
  end

  defp respond(conn, {:error, reason}) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:missing_table), do: {503, "missing_table"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
