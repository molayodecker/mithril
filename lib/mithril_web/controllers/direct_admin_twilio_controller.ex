defmodule MithrilWeb.DirectAdminTwilioController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.Twilio.MessageLog
  alias MithrilWeb.Schemas.DirectAdminTwilio.MessageLogResponse
  alias OpenApiSpex.Schema

  tags(["direct-admin-twilio"])

  operation(:messages,
    operation_id: "direct.listAdminTwilioMessages",
    summary: "List Twilio's own SMS and WhatsApp message history",
    parameters: [
      to: [in: :query, schema: %Schema{type: :string}, required: false],
      from: [in: :query, schema: %Schema{type: :string}, required: false],
      pageSize: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 100},
        required: false
      ],
      pageToken: [in: :query, schema: %Schema{type: :string}, required: false]
    ],
    responses: [ok: {"Twilio messages", "application/json", MessageLogResponse}]
  )

  def messages(conn, params) do
    case MessageLog.list(user_id(conn), params) do
      {:ok, page} ->
        json(conn, page)

      {:error, reason} ->
        {status, message} = error_response(reason)

        conn
        |> put_status(status)
        |> json(%{error: message})
    end
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:twilio_not_configured), do: {503, "twilio_not_configured"}
  defp error_response(:twilio_unavailable), do: {502, "twilio_unavailable"}
end
