defmodule Mithril.Notifications.OutboundTest do
  use ExUnit.Case, async: false

  alias Mithril.Notifications.Outbound

  setup do
    previous_sms_adapter = Application.get_env(:mithril, :sms_adapter)
    previous_sms_messages = Application.get_env(:mithril, :test_sms_messages)
    previous_resend_api_key = Application.get_env(:mithril, :resend_api_key)

    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Test)
    Application.put_env(:mithril, :test_sms_messages, [])
    Application.delete_env(:mithril, :resend_api_key)

    on_exit(fn ->
      restore_env(:sms_adapter, previous_sms_adapter)
      restore_env(:test_sms_messages, previous_sms_messages)
      restore_env(:resend_api_key, previous_resend_api_key)
    end)

    :ok
    defp restore_env(key, nil), do: Application.delete_env(:mithril, key)
  defp restore_env(key, value), do: Application.put_env(:mithril, key, value)
end

  test "sms channel sends a phone message and does not pretend WhatsApp succeeded" do
    result =
      Outbound.deliver(%{
        "template" => "booking_reminder",
        "channel" => "sms",
        "phone" => "+233200000001",
        "variables" => %{"date" => "2026-10-01", "recipientType" => "customer"}
      })

    assert result["smsSent"]
    refute result["whatsappSent"]
    assert [{"+233200000001", body}] = Application.get_env(:mithril, :test_sms_messages)
    assert body =~ "Instaclean reminder"
  end

  test "failed sms falls back to WhatsApp only when a template is configured" do
    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Disabled)

    result =
      Outbound.deliver(%{
        "template" => "booking_reminder",
        "channel" => "sms",
        "smsFallbackToWhatsapp" => true,
        "phone" => "+233200000001",
        "variables" => %{}
      })

    refute result["smsSent"]
    refute result["whatsappSent"]
  end
end
