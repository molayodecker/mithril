defmodule MithrilWeb.WhatsAppBookingOfferController do
  use Phoenix.Controller, formats: [:xml]

  alias Mithril.WhatsApp.BookingOffer

  def receive_message(conn, _params) do
    signature = conn |> get_req_header("x-twilio-signature") |> List.first()

    case BookingOffer.handle_webhook(conn.body_params, signature) do
      {:ok, xml} ->
        conn |> put_resp_content_type("text/xml") |> send_resp(200, xml)

      {:error, :unauthorized} ->
        send_resp(conn, 401, "Unauthorized")

      {:error, :not_configured} ->
        send_resp(conn, 503, "Not configured")
    end
  end
end
