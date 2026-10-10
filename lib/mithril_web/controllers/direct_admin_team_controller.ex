defmodule MithrilWeb.DirectAdminTeamController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminTeam
  alias MithrilWeb.Schemas.DirectAdminTeam.ListResponse

  tags(["direct-admin-team"])

  operation(:index,
    operation_id: "direct.listAdminTeam",
    summary: "List staff members with admin or reviewer roles",
    responses: [ok: {"Team", "application/json", ListResponse}]
  )

  def index(conn, _params) do
    respond(conn, DirectAdminTeam.list(user_id(conn)))
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
  defp error_response(:missing_table), do: {503, "missing_table"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
