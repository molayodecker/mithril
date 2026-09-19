defmodule Mithril.Notifications.RemindersTest do
  use ExUnit.Case, async: true

  alias Mithril.Notifications.Reminders

  test "one-off visits get 48h, 24h, morning, and cleaner stages" do
    assert Reminders.enabled_stages(%{}) == [
             "customer_48h",
             "customer_24h",
             "customer_morning",
             "cleaner"
           ]
  end

  test "weekly series skip the morning-of reminder and add a 7 day reminder" do
    assert Reminders.enabled_stages(%{recurrence_interval: "weekly"}) == [
             "customer_7d",
             "customer_48h",
             "customer_24h",
             "cleaner"
           ]

    assert Reminders.enabled_stages(%{recurrence_interval: "bi_weekly"}) ==
             Reminders.enabled_stages(%{recurrence_interval: "weekly"})
  end

  test "24h window is one hour wide around the target" do
    scheduled = DateTime.to_unix(~U[2026-10-02 09:00:00Z], :millisecond)
    on_target = DateTime.to_unix(~U[2026-10-01 09:00:00Z], :millisecond)
    too_early = DateTime.to_unix(~U[2026-10-01 07:00:00Z], :millisecond)

    assert Reminders.in_window?(scheduled, on_target, 24)
    refute Reminders.in_window?(scheduled, too_early, 24)
    refute Reminders.in_window?(scheduled, scheduled, 24)
  end

  test "morning-of window is 08:00 Africa/Accra on the visit date" do
    scheduled_ms = DateTime.to_unix(~U[2026-10-01 15:00:00Z], :millisecond)
    morning = DateTime.to_unix(~U[2026-10-01 08:00:00Z], :millisecond)
    previous_day = DateTime.to_unix(~U[2026-09-30 08:00:00Z], :millisecond)

    assert Reminders.morning_of?("2026-10-01", scheduled_ms, morning)
    refute Reminders.morning_of?("2026-10-01", scheduled_ms, previous_day)
  end
end
