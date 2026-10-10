defmodule MithrilWeb.DirectAdminPromotionsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminPromotions
  alias MithrilWeb.Schemas.DirectAdminPromotions.ListResponse

  tags(["direct-admin-promotions"])

  operation(:index,
    operation_id: "direct.listAdminPromotionCodes",
    summary: "List promotion codes with redemption stats",
    responses: [ok: {"Promotion codes", "application/json", ListResponse}]
  )

  def index(conn, _params) do
    respond(conn, DirectAdminPromotions.list_codes(user_id(conn)), fn codes -> %{codes: codes} end)
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
