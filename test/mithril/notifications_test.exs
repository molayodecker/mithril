defmodule Mithril.NotificationsTest do
  use ExUnit.Case, async: false

  alias Mithril.Notifications

  setup do
    previous = Application.get_env(:mithril, :test_sms_messages)
    Application.put_env(:mithril, :test_sms_messages, [])
    Application.delete_env(:mithril, :send_notification_url)
    Application.delete_env(:mithril, :send_notification_token)

    on_exit(fn ->
      if previous do
        Application.put_env(:mithril, :test_sms_messages, previous)
      else
        Application.delete_env(:mithril, :test_sms_messages)
      end
    end)

    :ok
  end

  test "sendNotifications defaults on and treats explicit false as skip" do
    assert Notifications.enabled?(%{})
    assert Notifications.enabled?(%{"sendNotifications" => true})
    refute Notifications.enabled?(%{"sendNotifications" => false})
    refute Notifications.enabled?(%{"sendNotifications" => "false"})
  end

  test "notify is a no-op when the admin opts out" do
    refute Notifications.notify(%{
             send_notifications: false,
             kind: :assisted_booking,
             customer: %{phone: "+233555000001", name: "Ama"},
             worker: %{phone: "+233555000002", name: "Kojo"},
             booking_id: Ecto.UUID.generate(),
             dates: ["2026-10-01"],
             scheduled_time: "09:00",
             address: "East Legon"
           })

    assert Application.get_env(:mithril, :test_sms_messages) == []
  end

  test "notify sends SMS to customer and professional when phones are present" do
    booking_id = Ecto.UUID.generate()

    assert Notifications.notify(%{
             send_notifications: true,
             kind: :assisted_booking,
             customer: %{phone: "+233555000001", name: "Ama"},
             worker: %{phone: "+233555000002", name: "Kojo"},
             booking_id: booking_id,
             dates: ["2026-10-01"],
             scheduled_time: "09:00:00",
             address: "East Legon"
           })

    phones =
      Application.get_env(:mithril, :test_sms_messages)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert phones == ["+233555000001", "+233555000002"]

    messages = Application.get_env(:mithril, :test_sms_messages) |> Enum.map(&elem(&1, 1))
    assert Enum.any?(messages, &String.contains?(&1, "Kojo is confirmed"))
    assert Enum.any?(messages, &String.contains?(&1, "New booking for Ama"))
    assert Enum.any?(messages, &String.contains?(&1, "/bookings/#{booking_id}"))
  end

  test "notify stays false when neither party has a phone" do
    refute Notifications.notify(%{
             send_notifications: true,
             kind: :assisted_booking,
             customer: %{email: "ama@example.com", name: "Ama"},
             worker: %{name: "Kojo"},
             booking_id: Ecto.UUID.generate(),
             dates: ["2026-10-01"],
             scheduled_time: "09:00",
             address: "East Legon"
           })

    assert Application.get_env(:mithril, :test_sms_messages) == []
  end

  test "assignment copy names the worker and household" do
    assert Notifications.notify(%{
             send_notifications: true,
             kind: :dispatch_assignment,
             request_id: Ecto.UUID.generate(),
             customer: %{phone: "+233555000001", name: "Ama"},
             worker: %{phone: "+233555000002", name: "Kojo"},
             address: "Cantonments, Accra",
             role: "elder_caregiver"
           })

    messages = Application.get_env(:mithril, :test_sms_messages) |> Enum.map(&elem(&1, 1))

    assert Enum.any?(
             messages,
             &String.contains?(&1, "Kojo is assigned for your elder caregiver request")
           )

    assert Enum.any?(messages, &String.contains?(&1, "New dispatch job · Cantonments, Accra"))
  end

  test "visit reminders only message the intended party" do
    assert Notifications.notify(%{
             send_notifications: true,
             kind: :booking_reminder,
             recipient: :customer,
             booking_id: Ecto.UUID.generate(),
             customer: %{phone: "+233555000001", name: "Ama"},
             worker: %{phone: "+233555000002", name: "Kojo"},
             dates: ["2026-10-01"],
             scheduled_time: "09:00",
             address: "East Legon"
           })

    messages = Application.get_env(:mithril, :test_sms_messages)
    assert length(messages) == 1
    assert {"+233555000001", body} = hd(messages)
    assert body =~ "Instaclean reminder"
    assert body =~ "Secure valuables"
  end
end
