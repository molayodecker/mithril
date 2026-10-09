defmodule MithrilWeb.DirectAdminServicesController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminServices

  alias MithrilWeb.Schemas.DirectAdminServices.{
    ListResponse,
    ServiceResponse,
    UpdateRequest
  }

  tags(["direct-admin-catalog"])

  operation(:index,
    operation_id: "direct.listAdminServices",
    summary: "List service types for staff pricing desk",
    responses: [ok: {"Services", "application/json", ListResponse}]
  )

  def index(conn, _params) do
    respond(conn, DirectAdminServices.list(user_id(conn)), fn services ->
      %{services: services}
    end)
  end

  operation(:show,
    operation_id: "direct.getAdminService",
    summary: "Get one service type",
    parameters: [id: [in: :path, type: :integer, required: true]],
    responses: [
      ok: {"Service", "application/json", ServiceResponse},
      not_found: {"Not found", "application/json", OpenApiSpex.JsonErrorResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    respond(conn, DirectAdminServices.get(user_id(conn), id), fn service ->
      %{service: service}
    end)
  end

  operation(:update,
    operation_id: "direct.updateAdminService",
    summary: "Update service pricing or visibility",
    parameters: [id: [in: :path, type: :integer, required: true]],
    request_body: {"Update service", "application/json", UpdateRequest},
    responses: [ok: {"Service", "application/json", ServiceResponse}]
  )

  def update(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminServices.update(user_id(conn), id, params), fn service ->
      %{service: service}
    end)
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
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:missing_table), do: {503, "missing_table"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
