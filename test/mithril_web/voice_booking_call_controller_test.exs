defmodule MithrilWeb.VoiceBookingCallControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  test "the arm route is authenticated and returns only the Twilio number" do
    spec = MithrilWeb.ApiSpec.spec()
    operation = spec.paths["/mobile/voice/booking-calls"].post
    response_schema = spec.components.schemas["VoiceBookingCallResponse"]

    assert operation.operationId == "mobile.armBookingVoiceCall"
    assert operation.security == [%{"bearerAuth" => []}]
    assert Map.has_key?(response_schema.properties, :dialNumber)
    refute Map.has_key?(response_schema.properties, :phone)
    assert :dialNumber in response_schema.required
  end

  test "arming a call without a session is rejected" do
    conn =
      post(build_conn(), "/mobile/voice/booking-calls", %{
        "bookingId" => "11111111-1111-1111-1111-111111111111",
        "contactRole" => "customer"
      })

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "an unsigned voice webhook is rejected" do
    Application.put_env(:mithril, :disable_twilio_signature_validation, false)

    conn =
      post(build_conn(), "/voice/booking-call", %{
        "From" => "+233200000002",
        "To" => "+233200000099",
        "CallSid" => "CA123"
      })

    assert response(conn, 401) == "Unauthorized"
  end
end
