defmodule MithrilWeb.DirectAdminInvoicesController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminInvoices

  alias MithrilWeb.Schemas.DirectAdminInvoice.{
    Invoice,
    SendRequest,
    SendResponse,
    UpsertRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-invoices"])

  operation(:show,
    operation_id: "direct.showAdminJobInvoice",
    summary: "Read the invoice saved for a booking",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    responses: [ok: {"Job invoice", "application/json", Invoice}]
  )

  def show(conn, %{"id" => id}) do
    respond(conn, DirectAdminInvoices.show(user_id(conn), id))
  end

  operation(:upsert,
    operation_id: "direct.upsertAdminJobInvoice",
    summary: "Create or update the invoice for a booking",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"Job invoice", "application/json", UpsertRequest, required: true},
    responses: [ok: {"Saved invoice", "application/json", Invoice}]
  )

  def upsert(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminInvoices.upsert(user_id(conn), id, params))
  end

  operation(:send,
    operation_id: "direct.sendAdminJobInvoice",
    summary: "Send the saved invoice by WhatsApp or email",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"Invoice delivery", "application/json", SendRequest, required: true},
    responses: [ok: {"Invoice sent", "application/json", SendResponse}]
  )

  def send(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminInvoices.send(user_id(conn), id, params))
  end

  operation(:public_show,
    operation_id: "direct.showPublicJobInvoice",
    summary: "Read an invoice by its public token",
    parameters: [
      token: [
        in: :path,
        schema: %Schema{type: :string},
        required: true,
        description: "Public invoice token"
      ]
    ],
    responses: [ok: {"Job invoice", "application/json", Invoice}]
  )

  def public_show(conn, %{"token" => token}) do
    respond(conn, DirectAdminInvoices.public_show(token))
  end

  defp user_id(conn), do: conn.assigns[:instaclean_user_id]

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
  defp error_response(:booking_not_found), do: {404, "booking_not_found"}
  defp error_response(:invoice_not_found), do: {404, "invoice_not_found"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invalid_invoice), do: {422, "invalid_invoice"}
  defp error_response(:invalid_lines), do: {422, "invalid_lines"}
  defp error_response(:invalid_phone), do: {422, "invalid_phone"}
  defp error_response(:invalid_email), do: {422, "invalid_email"}
  defp error_response(:missing_phone), do: {422, "missing_phone"}
  defp error_response(:missing_email), do: {422, "missing_email"}
  defp error_response(:amount_too_large), do: {422, "amount_too_large"}
  defp error_response(:twilio_not_configured), do: {503, "twilio_not_configured"}
  defp error_response(:sms_delivery_failed), do: {502, "sms_delivery_failed"}
  defp error_response(:email_not_configured), do: {503, "email_not_configured"}
  defp error_response(:email_delivery_failed), do: {502, "email_delivery_failed"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
