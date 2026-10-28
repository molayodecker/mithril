defmodule MithrilWeb.DirectPaymentStatusController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  alias Mithril.DirectPaymentRequests

  def update(conn, %{"token" => token}) do
    signature = conn |> get_req_header("x-twilio-signature") |> List.first()

    case DirectPaymentRequests.payment_status_callback(token, conn.body_params, signature) do
      :ok -> send_resp(conn, 204, "")
      {:error, :unauthorized} -> send_resp(conn, 401, "Unauthorized")
      {:error, _} -> send_resp(conn, 503, "Try again")
    end
  end
end
