defmodule MithrilWeb.MobileVoiceBookingCallController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.Voice.BookingCall
  alias MithrilWeb.Schemas.VoiceBookingCall.{Error, Request, Response}

  tags(["mobile"])

  operation(:create,
    operation_id: "mobile.armBookingVoiceCall",
    summary: "Arm a masked call for one booking",
    description:
      "Returns the public Twilio number the phone app should dial. The other party's number stays on the server.",
    request_body: {"Booking to call", "application/json", Request, required: true},
    responses: [
      ok: {"Twilio number to dial", "application/json", Response},
      unprocessable_entity: {"Call cannot be armed", "application/json", Error},
      unauthorized: {"Sign in required", "application/json", Error}
    ]
  )

  def create(conn, params) do
    user_id = conn.assigns.instaclean_user_id
    booking_id = params["bookingId"] || params["booking_id"]
    contact_role = params["contactRole"] || params["contact_role"]

    case BookingCall.arm(user_id, booking_id, contact_role) do
      {:ok, %{dial_number: dial_number}} ->
        json(conn, %{dialNumber: dial_number})

      {:error, reason} ->
        {status, code} = arm_error(reason)

        conn
        |> put_status(status)
        |> json(%{error: code})
    end
  end

  defp arm_error(:voice_not_configured), do: {503, "voice_not_configured"}
  defp arm_error(:caller_phone_missing), do: {422, "caller_phone_missing"}
  defp arm_error(:invalid_request), do: {400, "invalid_request"}
  defp arm_error(code) when is_binary(code), do: {422, code}
end
