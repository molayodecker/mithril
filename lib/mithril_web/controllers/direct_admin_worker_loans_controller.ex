defmodule MithrilWeb.DirectAdminWorkerLoansController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectWorkerLoans

  alias MithrilWeb.Schemas.DirectWorkerLoan.{
    Request,
    RequestList,
    ReviewRequest,
    ReviewResponse
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-worker-loans"])

  operation(:index,
    operation_id: "direct.listAdminWorkerLoanRequests",
    summary: "List worker loan requests for admin review",
    parameters: [
      status: [
        in: :query,
        schema: %Schema{
          type: :string,
          enum: ["pending", "approved", "rejected", "cancelled", "all"]
        },
        required: false,
        description: "Filter by status; defaults to pending"
      ]
    ],
    responses: [ok: {"Loan requests", "application/json", RequestList}]
  )

  def index(conn, params) do
    case DirectWorkerLoans.list_admin_requests(user_id(conn), params["status"]) do
      {:ok, requests} -> json(conn, %{requests: requests})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  operation(:show,
    operation_id: "direct.showAdminWorkerLoanRequest",
    summary: "Read one worker loan request",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [ok: {"Loan request", "application/json", Request}]
  )

  def show(conn, %{"id" => id}) do
    case DirectWorkerLoans.show_admin_request(user_id(conn), id) do
      {:ok, request} -> json(conn, request)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  operation(:review,
    operation_id: "direct.reviewAdminWorkerLoanRequest",
    summary: "Approve or reject a worker loan request",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Review", "application/json", ReviewRequest, required: true},
    responses: [ok: {"Review outcome", "application/json", ReviewResponse}]
  )

  def review(conn, %{"id" => id} = params) do
    case DirectWorkerLoans.review(user_id(conn), id, params) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond_error(conn, reason) do
    {status, message} = error_response(reason)
    conn |> put_status(status) |> json(%{error: message})
  end

  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:request_not_found), do: {404, "request_not_found"}
  defp error_response(:request_not_pending), do: {409, "request_not_pending"}
  defp error_response(:invalid_decision), do: {422, "invalid_decision"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:wallet_not_found), do: {409, "wallet_not_found"}
  defp error_response(:unsupported_currency), do: {422, "unsupported_currency"}
  defp error_response(:amount_too_large), do: {422, "amount_too_large"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
