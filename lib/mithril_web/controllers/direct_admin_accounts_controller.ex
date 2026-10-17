defmodule MithrilWeb.DirectAdminAccountsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminAccounts
  alias MithrilWeb.Schemas.DirectAdminAccounts.MergeRequest
  alias MithrilWeb.Schemas.DirectAdminAccounts.MergeResponse

  tags(["direct-admin-accounts"])

  operation(:merge,
    operation_id: "direct.mergeAdminAccounts",
    summary: "Merge a duplicate customer account into the primary account",
    request_body: {"Merge", "application/json", MergeRequest},
    responses: [ok: {"Merged", "application/json", MergeResponse}]
  )

  def merge(conn, params) do
    respond(conn, DirectAdminAccounts.merge(user_id(conn), params))
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

  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:missing_function), do: {503, "missing_function"}
  defp error_response(:missing_table), do: {503, "missing_table"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
