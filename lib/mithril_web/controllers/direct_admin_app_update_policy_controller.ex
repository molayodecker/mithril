defmodule MithrilWeb.DirectAdminAppUpdatePolicyController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminAppUpdatePolicy

  alias MithrilWeb.Schemas.DirectAdminAppUpdatePolicy.{
    ListResponse,
    SaveRequest,
    SaveResponse
  }

  tags(["direct-admin-settings"])

  operation(:index,
    operation_id: "direct.listAdminAppUpdatePolicies",
    summary: "List mobile app update policies by release channel",
    responses: [ok: {"Policies", "application/json", ListResponse}]
  )

  def index(conn, _params) do
    respond(conn, DirectAdminAppUpdatePolicy.list(user_id(conn)), fn policies ->
      %{policies: policies}
    end)
  end

  operation(:save,
    operation_id: "direct.saveAdminAppUpdatePolicy",
    summary: "Save a mobile app update policy for one release channel",
    request_body: {"Save policy", "application/json", SaveRequest},
    responses: [ok: {"Saved policy", "application/json", SaveResponse}]
  )

  def save(conn, params) do
    respond(conn, DirectAdminAppUpdatePolicy.save(user_id(conn), params), fn policy ->
      %{policy: policy}
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
