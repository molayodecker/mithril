defmodule Mithril.Notifications.SendNotificationTest do
  use ExUnit.Case, async: false

  alias Mithril.Notifications.SendNotification

  test "admin cleaner reminders use the booking reminder template" do
    assert SendNotification.template_for(:admin_notify_cleaner, :worker) ==
             {"booking_reminder", "direct_admin_cleaner_reminder"}
  end

  test "admin receipts use the payment receipt template" do
    assert SendNotification.template_for(:admin_receipt, :customer) ==
             {"payment_received", "direct_admin_receipt"}
  end

  test "existing booking template mappings remain unchanged" do
    assert SendNotification.template_for(:booking_reminder, :customer) ==
             {"booking_reminder", "direct_customer_reminder"}

    assert SendNotification.template_for(:assisted_booking, :worker) ==
             {"new_booking", "direct_worker"}

    assert SendNotification.template_for(:direct_assignment_offer, :worker) ==
             {"assignment_offer", "direct_assignment_offer"}

    assert SendNotification.template_for(:assisted_booking, :customer) ==
             {"cleaner_assigned", "direct_customer"}
  end

  test "a worker phone does not crash after the SMS post" do
    assert SendNotification.parallel_whatsapp?("+233200000001", sms_fallback_to_whatsapp: false)
    refute SendNotification.parallel_whatsapp?("+233200000001", sms_fallback_to_whatsapp: true)
    refute SendNotification.parallel_whatsapp?(nil, [])

    previous_url = Application.get_env(:mithril, :send_notification_url)
    previous_token = Application.get_env(:mithril, :send_notification_token)
    Application.put_env(:mithril, :send_notification_url, "http://127.0.0.1:9")
    Application.put_env(:mithril, :send_notification_token, "test-token")

    on_exit(fn ->
      restore_env(:send_notification_url, previous_url)
      restore_env(:send_notification_token, previous_token)
    end)

    assert SendNotification.deliver(%{
             recipient: :worker,
             kind: :direct_assignment_offer,
             booking_id: "00000000-0000-4000-8000-000000000001",
             worker: %{phone: "+233200000001", name: "Ama", user_id: "worker-1"},
             address: "Labone, Accra",
             service_name: "Regular cleaning",
             dates: ["2026-11-04"],
             scheduled_time: "11:00"
           }) == false
  end

  defp restore_env(key, nil), do: Application.delete_env(:mithril, key)
  defp restore_env(key, value), do: Application.put_env(:mithril, key, value)
end
