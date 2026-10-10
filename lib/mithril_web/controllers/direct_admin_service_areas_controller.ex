defmodule MithrilWeb.DirectAdminServiceAreasController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminServiceAreas
  alias MithrilWeb.Schemas.DirectAdminServiceAreas.ListResponse

  tags(["direct-admin-service-areas"])

  operation(:index,
    operation_id: "direct.listAdminServiceAreas",
    summary: "List geographic service areas and cleaner coverage",
    responses: [ok: {"Service areas", "application/json", ListResponse}]
  )

  def index(conn, _params) do
    respond(conn, DirectAdminServiceAreas.list(user_id(conn)), fn areas -> %{areas: areas} end)
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, result, mapper)

  defp respond(conn, {:ok, value}, mapper) do
    json(conn, mapper.(value))
  end

  defp respond(conn, {:error, reason}, _mapper) do
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
