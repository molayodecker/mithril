defmodule MithrilWeb.DirectAdminReviewsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminReviews
  alias MithrilWeb.Schemas.DirectAdminReviews.ListResponse
  alias OpenApiSpex.Schema

  tags(["direct-admin-reviews"])

  operation(:index,
    operation_id: "direct.listAdminReviews",
    summary: "List booking reviews for moderation",
    parameters: [
      filter: [in: :query, schema: %Schema{type: :string}, required: false]
    ],
    responses: [ok: {"Reviews", "application/json", ListResponse}]
  )

  def index(conn, params) do
    respond(conn, DirectAdminReviews.list(user_id(conn), params))
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
