defmodule MithrilWeb.DirectAdminBillingController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminBilling
  alias Mithril.DirectAdminBillingOutreach

  alias MithrilWeb.Schemas.DirectAdminBilling.{
    Advice,
    AdviceList,
    AdviceUpsertRequest,
    DecisionRequest,
    Invoice,
    InvoiceList,
    InvoiceUpsertRequest,
    LocationRequest,
    MessageRequest,
    MessageResponse,
    PublicInvoice,
    TeamRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-billing"])

  operation(:index_invoices,
    operation_id: "direct.listAdminBillingInvoices",
    summary: "List custom invoices",
    responses: [ok: {"Custom invoices", "application/json", InvoiceList}]
  )

  def index_invoices(conn, params) do
    case DirectAdminBilling.list_invoices(user_id(conn), Map.get(params, "page", 1)) do
      {:ok, invoices} -> json(conn, %{invoices: invoices})
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:upsert_invoice,
    operation_id: "direct.upsertAdminBillingInvoice",
    summary: "Create or update a custom invoice",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Invoice ID"
      ]
    ],
    request_body: {"Custom invoice", "application/json", InvoiceUpsertRequest, required: true},
    responses: [ok: {"Saved invoice", "application/json", Invoice}]
  )

  def upsert_invoice(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBilling.upsert_invoice(user_id(conn), id, params))
  end

  operation(:send_message,
    operation_id: "direct.sendAdminBillingInvoiceMessage",
    summary: "Send an invoice, approval request, location request, or team introduction",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Invoice ID"
      ]
    ],
    request_body: {"Invoice message", "application/json", MessageRequest, required: true},
    responses: [ok: {"Message sent", "application/json", MessageResponse}]
  )

  def send_message(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBillingOutreach.send(user_id(conn), id, params))
  end

  operation(:set_team,
    operation_id: "direct.setAdminBillingInvoiceTeam",
    summary: "Save the proposed team on a custom invoice",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Invoice ID"
      ]
    ],
    request_body: {"Proposed team", "application/json", TeamRequest, required: true},
    responses: [ok: {"Saved invoice", "application/json", Invoice}]
  )

  def set_team(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBillingOutreach.set_team(user_id(conn), id, params))
  end

  operation(:public_show,
    operation_id: "direct.showPublicBillingInvoice",
    summary: "Read a custom invoice by its public token",
    parameters: [
      token: [
        in: :path,
        schema: %Schema{type: :string},
        required: true,
        description: "Public invoice token"
      ]
    ],
    responses: [ok: {"Public invoice", "application/json", PublicInvoice}]
  )

  def public_show(conn, %{"token" => token}) do
    respond(conn, DirectAdminBillingOutreach.public_show(token))
  end

  operation(:decide,
    operation_id: "direct.decidePublicBillingInvoice",
    summary: "Approve a custom invoice or request a change",
    parameters: [
      token: [
        in: :path,
        schema: %Schema{type: :string},
        required: true,
        description: "Public invoice token"
      ]
    ],
    request_body: {"Invoice decision", "application/json", DecisionRequest, required: true},
    responses: [ok: {"Updated invoice", "application/json", PublicInvoice}]
  )

  def decide(conn, %{"token" => token} = params) do
    respond(conn, DirectAdminBillingOutreach.decide(token, params))
  end

  operation(:share_location,
    operation_id: "direct.sharePublicBillingInvoiceLocation",
    summary: "Share the service address for a custom invoice",
    parameters: [
      token: [
        in: :path,
        schema: %Schema{type: :string},
        required: true,
        description: "Public invoice token"
      ]
    ],
    request_body: {"Service address", "application/json", LocationRequest, required: true},
    responses: [ok: {"Updated invoice", "application/json", PublicInvoice}]
  )

  def share_location(conn, %{"token" => token} = params) do
    respond(conn, DirectAdminBillingOutreach.share_location(token, params))
  end

  operation(:index_advices,
    operation_id: "direct.listAdminPaymentAdvices",
    summary: "List payment advice",
    responses: [ok: {"Payment advice", "application/json", AdviceList}]
  )

  def index_advices(conn, params) do
    case DirectAdminBilling.list_advices(user_id(conn), Map.get(params, "page", 1)) do
      {:ok, advices} -> json(conn, %{advices: advices})
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:upsert_advice,
    operation_id: "direct.upsertAdminPaymentAdvice",
    summary: "Create or update a payment advice",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Payment advice ID"
      ]
    ],
    request_body: {"Payment advice", "application/json", AdviceUpsertRequest, required: true},
    responses: [ok: {"Saved payment advice", "application/json", Advice}]
  )

  def upsert_advice(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBilling.upsert_advice(user_id(conn), id, params))
  end

  defp user_id(conn), do: conn.assigns[:instaclean_user_id]

  defp respond(conn, {:ok, payload}), do: json(conn, payload)
  defp respond(conn, {:error, reason}), do: error(conn, reason)

  defp error(conn, reason) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:invoice_not_found), do: {404, "invoice_not_found"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invoice_not_sent), do: {422, "invoice_not_sent"}
  defp error_response(:already_approved), do: {422, "already_approved"}
  defp error_response(:location_not_requested), do: {422, "location_not_requested"}
  defp error_response(:team_not_ready), do: {422, "team_not_ready"}
  defp error_response(:team_empty), do: {422, "team_empty"}
  defp error_response(:team_already_sent), do: {422, "team_already_sent"}
  defp error_response(:invalid_workers), do: {422, "invalid_workers"}
  defp error_response(:missing_phone), do: {422, "missing_phone"}
  defp error_response(:missing_email), do: {422, "missing_email"}
  defp error_response(:twilio_not_configured), do: {503, "twilio_not_configured"}
  defp error_response(:sms_not_configured), do: {503, "sms_not_configured"}
  defp error_response(:sms_delivery_failed), do: {502, "sms_delivery_failed"}
  defp error_response(:email_not_configured), do: {503, "email_not_configured"}
  defp error_response(:email_delivery_failed), do: {502, "email_delivery_failed"}
  defp error_response(:invalid_invoice), do: {422, "invalid_invoice"}
  defp error_response(:invalid_lines), do: {422, "invalid_lines"}
  defp error_response(:invalid_email), do: {422, "invalid_email"}
  defp error_response(:invalid_form_type), do: {422, "invalid_form_type"}
  defp error_response(:amount_too_large), do: {422, "amount_too_large"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
