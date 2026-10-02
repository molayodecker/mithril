defmodule MithrilWeb.StripeWebhookController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Mithril.Stripe.Webhook
  alias MithrilWeb.CacheBodyReader

  def create(conn, _params) do
    raw_body = CacheBodyReader.body(conn)
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case Webhook.handle(raw_body, signature) do
      {:ok, result} ->
        json(conn, %{
          ok: true,
          event: Map.get(result, :event),
          ignored: Map.get(result, :ignored, false),
          settled: Map.get(result, :settled, false),
          alreadyPaid: Map.get(result, :already_paid, false),
          refunded: Map.get(result, :refunded, false),
          reference: Map.get(result, :reference)
        })

      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "Invalid webhook signature"})

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Missing STRIPE_WEBHOOK_SECRET"})

      {:error, reason}
      when reason in [:invalid_json, :invalid_payload] ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid Stripe webhook payload"})

      {:error, reason}
      when reason in [:amount_mismatch, :payment_reference_mismatch, :payment_conflict] ->
        conn |> put_status(:conflict) |> json(%{error: Atom.to_string(reason)})

      {:error, :provider_unavailable} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Stripe refund unavailable"})

      {:error, :database_unavailable} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to persist Stripe webhook"})
    end
  end
end
