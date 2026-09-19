defmodule MithrilWeb.DirectAdminDispatchMapController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminDispatchMap
  alias MithrilWeb.Schemas.DirectAdminDispatchMap.MapResponse
  alias OpenApiSpex.Schema

  tags(["direct-admin-dispatch-map"])

  operation(:show,
    operation_id: "direct.getAdminDispatchMap",
    summary: "Load cleaner and customer booking locations for the dispatch map",
    parameters: [
      daysAhead: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 90},
        required: false
      ],
      statuses: [
        in: :query,
        schema: %Schema{type: :string},
        required: false,
        description: "Comma-separated booking statuses"
      ]
    ],
    responses: [ok: {"Dispatch map", "application/json", MapResponse}]
  )

  def show(conn, params) do
    respond(conn, DirectAdminDispatchMap.load(user_id(conn), normalize(params)))
  end

  defp normalize(params) do
    statuses =
      case params["statuses"] do
        value when is_binary(value) -> String.split(value, ",", trim: true)
        value when is_list(value) -> value
        _ -> nil
      end

    params
    |> Map.put("statuses", statuses)
    |> Map.put("daysAhead", params["daysAhead"])
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, {:ok, value}) do
    json(conn, value)
  end

  defp respond(conn, {:error, reason}) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
