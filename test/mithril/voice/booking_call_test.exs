defmodule Mithril.Voice.BookingCallTest do
  use ExUnit.Case, async: false

  alias Mithril.Voice.BookingCall
  alias Mithril.Voice.BookingCall.Memory

  @user_id "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @booking_id "11111111-1111-1111-1111-111111111111"
  @other_booking_id "22222222-2222-2222-2222-222222222222"
  @caller_phone "+233200000002"
  @destination_phone "+233200000001"
  @site_phone "+233200000004"
  @voice_number "+233200000099"
  @webhook_url "https://api.tryinstaclean.com/voice/booking-call"

  setup do
    previous_lookup = Application.get_env(:mithril, :voice_contact_lookup)
    previous_caller = Application.get_env(:mithril, :voice_caller_phone)
    previous_voice_number = Application.get_env(:mithril, :twilio_voice_number)
    previous_from_number = Application.get_env(:mithril, :twilio_from_number)

    previous_signature_validation =
      Application.get_env(:mithril, :disable_twilio_signature_validation)

    Application.put_env(:mithril, :disable_twilio_signature_validation, false)

    Application.put_env(:mithril, :voice_contact_lookup, fn _user_id, _booking_id, role ->
      case role do
        "site" -> {:ok, @site_phone}
        _customer -> {:ok, @destination_phone}
      end
    end)

    Application.put_env(:mithril, :voice_caller_phone, fn _user_id -> {:ok, @caller_phone} end)
    Memory.reset()

    on_exit(fn ->
      restore_env(:voice_contact_lookup, previous_lookup)
      restore_env(:voice_caller_phone, previous_caller)
      restore_env(:twilio_voice_number, previous_voice_number)
      restore_env(:twilio_from_number, previous_from_number)
      restore_env(:disable_twilio_signature_validation, previous_signature_validation)
      Memory.reset()
    end)

    :ok
  end

  test "arming a call returns only the public Twilio number" do
    assert {:ok, response} = BookingCall.arm(@user_id, @booking_id, "customer")
    assert response == %{dial_number: @voice_number}
    refute Map.has_key?(response, :phone)
    refute Map.has_key?(response, :destination)
  end

  test "a refused booking does not leave a call intent" do
    Application.put_env(:mithril, :voice_contact_lookup, fn _user, _booking, _role ->
      {:error, "assignment_pending"}
    end)

    assert {:error, "assignment_pending"} = BookingCall.arm(@user_id, @booking_id, nil)
    assert Memory.intent_count() == 0
  end

  test "a caller without an account phone cannot arm a call" do
    Application.put_env(:mithril, :voice_caller_phone, fn _user -> :missing end)

    assert {:error, :caller_phone_missing} = BookingCall.arm(@user_id, @booking_id, "customer")
    assert Memory.intent_count() == 0
  end

  test "calling stays unavailable until a voice number is configured" do
    Application.delete_env(:mithril, :twilio_voice_number)
    Application.delete_env(:mithril, :twilio_from_number)

    assert {:error, :voice_not_configured} = BookingCall.arm(@user_id, @booking_id, "customer")
  end

  test "a signed webhook dials the other party with the Twilio caller ID" do
    assert {:ok, _response} = BookingCall.arm(@user_id, @booking_id, "customer")

    assert {:ok, xml} =
             BookingCall.handle_webhook(call_params(), sign(call_params()), @webhook_url)

    assert xml =~ ~s(callerId="#{@voice_number}")
    assert xml =~ "<Number>#{@destination_phone}</Number>"
    refute xml =~ @caller_phone
  end

  test "a site call dials the on-site phone, not the customer phone" do
    assert {:ok, _response} = BookingCall.arm(@user_id, @booking_id, "site")

    assert {:ok, xml} =
             BookingCall.handle_webhook(call_params(), sign(call_params()), @webhook_url)

    assert xml =~ "<Number>#{@site_phone}</Number>"
    refute xml =~ @destination_phone
    refute xml =~ @caller_phone
  end

  test "the newest armed booking wins when the same phone calls in" do
    parent = self()

    Application.put_env(:mithril, :voice_contact_lookup, fn _user, booking_id, _role ->
      send(parent, {:lookup, booking_id})

      case booking_id do
        @booking_id -> {:ok, @destination_phone}
        @other_booking_id -> {:ok, @site_phone}
      end
    end)

    assert {:ok, _} = BookingCall.arm(@user_id, @booking_id, "customer")
    assert {:ok, _} = BookingCall.arm(@user_id, @other_booking_id, "customer")

    assert {:ok, xml} =
             BookingCall.handle_webhook(call_params(), sign(call_params()), @webhook_url)

    assert xml =~ "<Number>#{@site_phone}</Number>"
    refute xml =~ "<Number>#{@destination_phone}</Number>"
  end

  test "an unsigned webhook is rejected and does not dial" do
    assert {:ok, _} = BookingCall.arm(@user_id, @booking_id, "customer")

    assert {:error, :unauthorized} =
             BookingCall.handle_webhook(call_params(), nil, @webhook_url)
  end

  test "a signed call from a different phone does not reveal the destination" do
    assert {:ok, _} = BookingCall.arm(@user_id, @booking_id, "customer")
    params = %{"From" => "+233200000003", "To" => @voice_number, "CallSid" => "CA1"}

    assert {:ok, xml} = BookingCall.handle_webhook(params, sign(params), @webhook_url)

    refute xml =~ "<Number>"
    refute xml =~ @destination_phone
    refute xml =~ @caller_phone
  end

  test "one active job can be reached by calling the Twilio number again" do
    Memory.put_active_routes(@caller_phone, [
      %{user_id: @user_id, booking_id: @booking_id, contact_role: "customer"}
    ])

    assert {:ok, xml} =
             BookingCall.handle_webhook(call_params(), sign(call_params()), @webhook_url)

    assert xml =~ "<Number>#{@destination_phone}</Number>"
    refute xml =~ @caller_phone
  end

  test "an expired tap falls through to the one active job" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      Memory.put_intent(%{
        caller_user_id: @user_id,
        booking_id: @other_booking_id,
        contact_role: "site",
        caller_phone_e164: @caller_phone,
        expires_at: DateTime.add(now, -30, :second),
        created_at: now
      })

    Memory.put_active_routes(@caller_phone, [
      %{user_id: @user_id, booking_id: @booking_id, contact_role: "customer"}
    ])

    assert {:ok, xml} =
             BookingCall.handle_webhook(call_params(), sign(call_params()), @webhook_url)

    assert xml =~ "<Number>#{@destination_phone}</Number>"
    refute xml =~ @site_phone
  end

  test "several active jobs ask the caller to pick one in the app" do
    parent = self()

    Application.put_env(:mithril, :voice_contact_lookup, fn user_id, booking_id, role ->
      send(parent, {:lookup, user_id, booking_id, role})
      {:ok, @destination_phone}
    end)

    Memory.put_active_routes(@caller_phone, [
      %{user_id: @user_id, booking_id: @booking_id, contact_role: "customer"},
      %{user_id: @user_id, booking_id: @other_booking_id, contact_role: "customer"}
    ])

    assert {:ok, xml} =
             BookingCall.handle_webhook(call_params(), sign(call_params()), @webhook_url)

    refute xml =~ "<Number>"
    refute xml =~ @destination_phone
    assert xml =~ "more than one active job"
    refute_received {:lookup, _, _, _}
  end

  defp call_params do
    %{"From" => @caller_phone, "To" => @voice_number, "CallSid" => "CA123"}
  end

  defp sign(params) do
    token = Application.get_env(:mithril, :twilio_auth_token)

    payload =
      params
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(@webhook_url, fn {key, value}, acc -> acc <> key <> value end)

    :crypto.mac(:hmac, :sha, token, payload)
    |> Base.encode64()
  end

  defp restore_env(key, nil), do: Application.delete_env(:mithril, key)
  defp restore_env(key, value), do: Application.put_env(:mithril, key, value)
end
