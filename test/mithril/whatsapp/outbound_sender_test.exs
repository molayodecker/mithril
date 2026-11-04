defmodule Mithril.WhatsApp.OutboundSenderTest do
  use ExUnit.Case, async: false

  alias Mithril.WhatsApp.Recruitment.Outbound

  @whatsapp_from "whatsapp:+233246326939"
  @admin_from "+233559100642"
  @sms_service "MGsms0000000000000000000000000000"
  @whatsapp_service "MGwa00000000000000000000000000000"
  @admin_service "MGadmin000000000000000000000000000"

  setup do
    previous = %{
      sms: Application.get_env(:mithril, :twilio_messaging_service_sid),
      whatsapp: Application.get_env(:mithril, :twilio_whatsapp_messaging_service_sid),
      admin_service: Application.get_env(:mithril, :twilio_whatsapp_admin_messaging_service_sid),
      whatsapp_from: Application.get_env(:mithril, :twilio_whatsapp_from),
      admin_from: Application.get_env(:mithril, :twilio_whatsapp_admin_from)
    }

    Application.put_env(:mithril, :twilio_messaging_service_sid, @sms_service)
    Application.put_env(:mithril, :twilio_whatsapp_messaging_service_sid, @whatsapp_service)
    Application.put_env(:mithril, :twilio_whatsapp_admin_messaging_service_sid, @admin_service)
    Application.put_env(:mithril, :twilio_whatsapp_from, @whatsapp_from)
    Application.put_env(:mithril, :twilio_whatsapp_admin_from, @admin_from)

    on_exit(fn ->
      restore(:twilio_messaging_service_sid, previous.sms)
      restore(:twilio_whatsapp_messaging_service_sid, previous.whatsapp)
      restore(:twilio_whatsapp_admin_messaging_service_sid, previous.admin_service)
      restore(:twilio_whatsapp_from, previous.whatsapp_from)
      restore(:twilio_whatsapp_admin_from, previous.admin_from)
    end)

    :ok
  end

  test "the main WhatsApp number uses its own messaging service" do
    assert Outbound.sender_fields(@whatsapp_from) == [
             {"From", @whatsapp_from},
             {"MessagingServiceSid", @whatsapp_service}
           ]
  end

  test "the admin WhatsApp number uses the admin messaging service" do
    assert Outbound.sender_fields("whatsapp:#{@admin_from}") == [
             {"From", "whatsapp:#{@admin_from}"},
             {"MessagingServiceSid", @admin_service}
           ]
  end

  test "neither WhatsApp sender falls back to the SMS messaging service" do
    Application.delete_env(:mithril, :twilio_whatsapp_messaging_service_sid)
    Application.delete_env(:mithril, :twilio_whatsapp_admin_messaging_service_sid)

    assert Outbound.sender_fields(@whatsapp_from) == [{"From", @whatsapp_from}]

    assert Outbound.sender_fields("whatsapp:#{@admin_from}") == [
             {"From", "whatsapp:#{@admin_from}"}
           ]
  end

  defp restore(key, nil), do: Application.delete_env(:mithril, key)
  defp restore(key, value), do: Application.put_env(:mithril, key, value)
end
