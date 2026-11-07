defmodule MithrilWeb.DirectAdminPayoutNameReviewsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminPayoutNameReviews

  alias MithrilWeb.Schemas.DirectAdminPayoutNameReviews.{
    Decision,
    DecisionResponse,
    ListResponse,
    Review
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-payout-name-reviews"])

  operation(:index,
    operation_id: "direct.listAdminPayoutNameReviews",
    summary: "List payout name reviews waiting for approval",
    parameters: [
      status: [
        in: :query,
        schema: %Schema{type: :string, enum: ["pending", "approved", "rejected", "all"]},
        required: false,
        description: "Filter by status. Defaults to pending."
      ]
    ],
    responses: [ok: {"Payout name reviews", "application/json", ListResponse}]
  )

  def index(conn, params) do
    case DirectAdminPayoutNameReviews.list(user_id(conn), params) do
      {:ok, reviews} -> json(conn, %{reviews: reviews})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  operation(:show,
    operation_id: "direct.showAdminPayoutNameReview",
    summary: "Read one payout name review",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [ok: {"Payout name review", "application/json", Review}]
  )

  def show(conn, %{"id" => id}) do
    case DirectAdminPayoutNameReviews.show(user_id(conn), id) do
      {:ok, review} -> json(conn, review)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  operation(:review,
    operation_id: "direct.reviewAdminPayoutName",
    summary: "Approve or reject a payout name that does not match the account",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Decision", "application/json", Decision, required: true},
    responses: [ok: {"Review outcome", "application/json", DecisionResponse}]
  )

  def review(conn, %{"id" => id} = params) do
    case DirectAdminPayoutNameReviews.review(user_id(conn), id, params) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond_error(conn, reason) do
    {status, message} = error_response(reason)
    conn |> put_status(status) |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:review_not_found), do: {404, "review_not_found"}
  defp error_response(:review_not_pending), do: {409, "review_not_pending"}
  defp error_response(:invalid_decision), do: {422, "invalid_decision"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:missing_table), do: {503, "missing_table"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
