defmodule MithrilWeb.DirectAdminReportsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminReports
  alias MithrilWeb.Schemas.DirectAdminReports.SummaryResponse
  alias OpenApiSpex.Schema

  tags(["direct-admin-reports"])

  operation(:summary,
    operation_id: "direct.getAdminReportsSummary",
    summary: "Operations summary for a recent window",
    parameters: [
      days: [
        in: :query,
        schema: %Schema{type: :integer, enum: [7, 30, 90]},
        required: false
      ]
    ],
    responses: [ok: {"Summary", "application/json", SummaryResponse}]
  )

  def summary(conn, params) do
    respond(conn, DirectAdminReports.summary(user_id(conn), params))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, {:ok, summary}) do
    json(conn, %{summary: summary})
  end

  defp respond(conn, {:error, reason}) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:missing_table), do: {503, "missing_table"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
