defmodule MithrilWeb.VoiceBookingCallWebhookController do
  use Phoenix.Controller, formats: [:xml]

  alias Mithril.Voice.BookingCall

  def inbound(conn, _params) do
    signature = conn |> get_req_header("x-twilio-signature") |> List.first()

    case BookingCall.handle_webhook(conn.body_params, signature, request_url(conn)) do
      {:ok, xml} ->
        conn
        |> put_resp_content_type("text/xml")
        |> send_resp(200, xml)

      {:error, :unauthorized} ->
        send_resp(conn, 401, "Unauthorized")

      {:error, :not_configured} ->
        send_resp(conn, 503, "Not configured")
    end
  end
end
