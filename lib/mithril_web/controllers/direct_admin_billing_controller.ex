defmodule MithrilWeb.DirectAdminBillingController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminBilling

  alias MithrilWeb.Schemas.DirectAdminBilling.{
    Advice,
    AdviceList,
    AdviceUpsertRequest,
    Invoice,
    InvoiceList,
    InvoiceUpsertRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-billing"])

  operation(:index_invoices,
    operation_id: "direct.listAdminBillingInvoices",
    summary: "List custom invoices",
    responses: [ok: {"Custom invoices", "application/json", InvoiceList}]
  )

  def index_invoices(conn, _params) do
    case DirectAdminBilling.list_invoices(user_id(conn)) do
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

  operation(:index_advices,
    operation_id: "direct.listAdminPaymentAdvices",
    summary: "List payment advice",
    responses: [ok: {"Payment advice", "application/json", AdviceList}]
  )

  def index_advices(conn, _params) do
    case DirectAdminBilling.list_advices(user_id(conn)) do
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
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invalid_invoice), do: {422, "invalid_invoice"}
  defp error_response(:invalid_lines), do: {422, "invalid_lines"}
  defp error_response(:invalid_email), do: {422, "invalid_email"}
  defp error_response(:invalid_form_type), do: {422, "invalid_form_type"}
  defp error_response(:amount_too_large), do: {422, "amount_too_large"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
