defmodule MithrilWeb.DirectWorkerLoansController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectWorkerLoans

  alias MithrilWeb.Schemas.DirectWorkerLoan.{
    CreateRequest,
    Request,
    RequestList,
    Summary
  }

  tags(["direct-worker-loans"])

  operation(:index,
    operation_id: "direct.listWorkerLoanRequests",
    summary: "List the signed-in worker's loan requests",
    responses: [ok: {"Loan requests", "application/json", RequestList}]
  )

  def index(conn, _params) do
    case DirectWorkerLoans.list_worker_requests(user_id(conn)) do
      {:ok, requests} -> json(conn, %{requests: requests})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  operation(:create,
    operation_id: "direct.createWorkerLoanRequest",
    summary: "Request a loan or advance",
    request_body: {"Loan request", "application/json", CreateRequest, required: true},
    responses: [ok: {"Created request", "application/json", Request}]
  )

  def create(conn, params) do
    case DirectWorkerLoans.create_request(user_id(conn), params) do
      {:ok, request} -> json(conn, request)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  operation(:summary,
    operation_id: "direct.showWorkerLoanSummary",
    summary: "Outstanding loan balance for the signed-in worker",
    responses: [ok: {"Loan summary", "application/json", Summary}]
  )

  def summary(conn, _params) do
    case DirectWorkerLoans.worker_summary(user_id(conn)) do
      {:ok, summary} -> json(conn, summary)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond_error(conn, reason) do
    {status, message} = error_response(reason)
    conn |> put_status(status) |> json(%{error: message})
  end

  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:worker_not_found), do: {404, "worker_not_found"}
  defp error_response(:pending_request_exists), do: {409, "pending_request_exists"}
  defp error_response(:invalid_amount), do: {422, "invalid_amount"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
