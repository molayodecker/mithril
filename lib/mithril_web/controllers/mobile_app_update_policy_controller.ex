defmodule MithrilWeb.MobileAppUpdatePolicyController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.AppUpdatePolicy
  alias MithrilWeb.Schemas.MobileAppUpdatePolicy.Response
  alias OpenApiSpex.Schema

  tags(["mobile-calls"])

  operation(:show,
    operation_id: "mobile.getAppUpdatePolicy",
    summary: "Read the store update policy for one app and release channel",
    parameters: [
      app: [
        in: :query,
        required: true,
        schema: %Schema{type: :string, enum: ["customer", "worker"]}
      ],
      channel: [
        in: :query,
        required: true,
        schema: %Schema{type: :string, enum: ["production", "preview"]}
      ]
    ],
    responses: [
      ok: {"One policy, or null when none exists", "application/json", Response}
    ]
  )

  def show(conn, params) do
    case AppUpdatePolicy.fetch(params["app"], params["channel"]) do
      {:ok, policy} ->
        json(conn, %{data: policy})

      {:error, reason} ->
        {status, message} = error_response(reason)

        conn
        |> put_status(status)
        |> json(%{error: message})
    end
  end

  defp error_response(:bad_request), do: {400, "bad_request"}
  defp error_response(:multiple_rows), do: {409, "multiple_rows"}
  defp error_response(:missing_table), do: {503, "missing_table"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
end
