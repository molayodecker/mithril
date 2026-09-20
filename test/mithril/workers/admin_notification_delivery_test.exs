defmodule Mithril.Workers.AdminNotificationDeliveryTest do
  use ExUnit.Case, async: false

  alias Mithril.Workers.AdminNotificationDelivery

  setup do
    Application.put_env(:mithril, :test_sms_messages, [])
    :ok
  end

  test "sends SMS and discards unconfigured WhatsApp" do
    assert :ok =
             AdminNotificationDelivery.perform(%Oban.Job{
               args: %{
                 "channel" => "sms",
                 "phone" => "+233555000001",
                 "body" => "Ops note"
               }
             })

    assert [{"+233555000001", "Ops note"}] = Application.get_env(:mithril, :test_sms_messages)

    assert :discard =
             AdminNotificationDelivery.perform(%Oban.Job{
               args: %{
                 "channel" => "whatsapp",
                 "admin_user_id" => Ecto.UUID.generate(),
                 "phone" => "+233555000001",
                 "body" => "Ops note"
               }
             })
  end

  test "discards unknown channels" do
    assert :discard = AdminNotificationDelivery.perform(%Oban.Job{args: %{"channel" => "email"}})
  end
end
