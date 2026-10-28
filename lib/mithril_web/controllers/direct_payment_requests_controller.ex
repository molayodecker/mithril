defmodule MithrilWeb.DirectPaymentRequestsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectPaymentRequests

  alias MithrilWeb.Schemas.DirectPaymentRequest.{
    Checkout,
    CheckoutRequest,
    Create,
    List,
    Public,
    Request,
    VerifyRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct-payment-requests"])

  operation(:index,
    operation_id: "direct.listAdminPaymentRequests",
    summary: "List recent payment requests",
    responses: [ok: {"Payment requests", "application/json", List}]
  )

  def index(conn, _params) do
    respond(conn, DirectPaymentRequests.list(user_id(conn)))
  end

  operation(:create,
    operation_id: "direct.createAdminPaymentRequest",
    summary: "Create a payment request and message the customer",
    request_body: {"Payment request", "application/json", Create, required: true},
    responses: [ok: {"Payment request", "application/json", Request}]
  )

  def create(conn, params) do
    respond(conn, DirectPaymentRequests.create(user_id(conn), params))
  end

  operation(:public_show,
    operation_id: "direct.showPublicPaymentRequest",
    summary: "Read a payment request by its public token",
    parameters: [
      token: [
        in: :path,
        schema: %Schema{type: :string},
        required: true,
        description: "Public payment token"
      ]
    ],
    responses: [ok: {"Payment request", "application/json", Public}]
  )

  def public_show(conn, %{"token" => token}) do
    respond(conn, DirectPaymentRequests.public_show(token))
  end

  operation(:checkout,
    operation_id: "direct.checkoutPublicPaymentRequest",
    summary: "Start Paystack checkout for a public payment request",
    parameters: [
      token: [
        in: :path,
        schema: %Schema{type: :string},
        required: true,
        description: "Public payment token"
      ]
    ],
    request_body: {"Checkout", "application/json", CheckoutRequest, required: false},
    responses: [ok: {"Paystack checkout", "application/json", Checkout}]
  )

  def checkout(conn, %{"token" => token} = params) do
    respond(conn, DirectPaymentRequests.checkout(token, params))
  end

  operation(:verify,
    operation_id: "direct.verifyPublicPaymentRequest",
    summary: "Confirm Paystack payment for a public payment request",
    parameters: [
      token: [
        in: :path,
        schema: %Schema{type: :string},
        required: true,
        description: "Public payment token"
      ]
    ],
    request_body: {"Payment verification", "application/json", VerifyRequest, required: true},
    responses: [ok: {"Payment request", "application/json", Public}]
  )

  def verify(conn, %{"token" => token} = params) do
    respond(conn, DirectPaymentRequests.verify(token, params))
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
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invalid_phone), do: {422, "invalid_phone"}
  defp error_response(:invalid_email), do: {422, "invalid_email"}
  defp error_response(:customer_not_found), do: {404, "customer_not_found"}
  defp error_response(:already_paid), do: {409, "already_paid"}
  defp error_response(:amount_mismatch), do: {409, "amount_mismatch"}
  defp error_response(:payment_incomplete), do: {409, "payment_incomplete"}
  defp error_response(:payment_conflict), do: {409, "payment_conflict"}
  defp error_response(:payment_not_configured), do: {503, "payment_not_configured"}
  defp error_response(:payment_unavailable), do: {502, "payment_unavailable"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(_), do: {500, "payment_request_failed"}
end
