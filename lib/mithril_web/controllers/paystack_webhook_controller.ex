defmodule MithrilWeb.PaystackWebhookController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Mithril.Paystack.Webhook
  alias MithrilWeb.CacheBodyReader

  def create(conn, _params) do
    raw_body = CacheBodyReader.body(conn)
    signature = conn |> get_req_header("x-paystack-signature") |> List.first()

    case Webhook.handle(raw_body, signature) do
      {:ok, result} ->
        json(conn, %{
          ok: true,
          requestId: result.request_id,
          event: result.event,
          ignored: Map.get(result, :ignored, false),
          settled: Map.get(result, :settled, false),
          alreadyPaid: Map.get(result, :already_paid, false),
          reference: Map.get(result, :reference),
          refundStatus: Map.get(result, :refund_status)
        })

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid webhook signature"})

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Missing PAYSTACK_SECRET_KEY"})

      {:error, :invalid_json} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid JSON payload"})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing event"})

      {:error, :amount_mismatch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Amount mismatch"})

      {:error, :payment_incomplete} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Payment incomplete"})

      {:error, :payment_reference_mismatch} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Payment reference mismatch"})

      {:error, :payment_not_payable} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Booking is no longer payable"})

      {:error, :database_unavailable} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to persist Paystack webhook"})
    end
  end
end
