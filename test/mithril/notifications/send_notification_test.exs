defmodule Mithril.Notifications.SendNotificationTest do
  use ExUnit.Case, async: true

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

    assert SendNotification.template_for(:assisted_booking, :customer) ==
             {"cleaner_assigned", "direct_customer"}
  end
end
