defmodule Mithril.Notifications.OutboundTest do
  use ExUnit.Case, async: false

  alias Mithril.Notifications.Outbound

  setup do
    previous = Application.get_env(:mithril, :sms_adapter)
    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Test)
    Application.put_env(:mithril, :test_sms_messages, [])
    Application.delete_env(:mithril, :resend_api_key)

    on_exit(fn ->
      if previous, do: Application.put_env(:mithril, :sms_adapter, previous)
    end)

    :ok
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
