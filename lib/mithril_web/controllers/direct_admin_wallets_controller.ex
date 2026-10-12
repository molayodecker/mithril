defmodule MithrilWeb.DirectAdminWalletsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminWallets

  alias MithrilWeb.Schemas.DirectAdminWallet.{
    CreditRequest,
    CreditResponse,
    Wallet
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-wallets"])

  operation(:show,
    operation_id: "direct.showAdminWorkerWallet",
    summary: "Read a worker wallet balance",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Worker user ID"
      ]
    ],
    responses: [ok: {"Worker wallet", "application/json", Wallet}]
  )

  def show(conn, %{"id" => id}) do
    respond(conn, DirectAdminWallets.show(user_id(conn), id))
  end

  operation(:credit,
    operation_id: "direct.creditAdminWorkerWallet",
    summary: "Add money to a worker wallet",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Worker user ID"
      ]
    ],
    request_body: {"Wallet credit", "application/json", CreditRequest, required: true},
    responses: [ok: {"Recorded credit", "application/json", CreditResponse}]
  )

  def credit(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminWallets.credit(user_id(conn), id, params))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

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
  defp error_response(:worker_not_found), do: {404, "worker_not_found"}
  defp error_response(:wallet_not_found), do: {409, "wallet_not_found"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invalid_amount), do: {422, "invalid_amount"}
  defp error_response(:invalid_notes), do: {422, "invalid_notes"}
  defp error_response(:unsupported_currency), do: {422, "unsupported_currency"}
  defp error_response(:amount_too_large), do: {422, "amount_too_large"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
