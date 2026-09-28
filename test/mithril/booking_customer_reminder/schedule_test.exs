defmodule Mithril.BookingCustomerReminder.ScheduleTest do
  use ExUnit.Case, async: true

  alias Mithril.BookingCustomerReminder.Schedule

  @claim_ttl_ms 45 * 60 * 1000

  defp base_row(overrides) do
    Map.merge(
      %{
        "id" => "b1",
        "status" => "confirmed",
        "payment_status" => "paid",
        "schedule_group_id" => nil,
        "cleaner_id" => "cleaner-1",
        "customer_reminder_48h_sent_at" => nil,
        "customer_reminder_sent_at" => nil,
        "customer_reminder_morning_sent_at" => nil,
        "cleaner_reminder_sent_at" => nil,
        "scheduled_date" => "2099-07-01",
        "scheduled_time" => "10:00:00"
      },
      overrides
    )
  end

  test "closed schedule group still allows unfinished morning after 24h sent" do
    row =
      base_row(%{
        "payment_status" => "post_paid",
        "schedule_group_id" => "grp-1",
        "customer_reminder_48h_sent_at" => "2099-06-29T10:00:00Z",
        "customer_reminder_sent_at" => "2099-06-30T10:00:00Z",
        "cleaner_reminder_sent_at" => "2099-06-30T10:05:00Z",
        "customer_reminder_morning_sent_at" => nil
      })

    assert Schedule.eligible_row?(row, MapSet.new())
  end

  test "selectDue work items prioritize morning when batch-limited" do
    morning_now = DateTime.to_unix(~U[2099-07-10 08:00:00Z], :millisecond)

    morning_rows =
      for index <- 0..2 do
        base_row(%{
          "id" => "morning-#{index}",
          "scheduled_date" => "2099-07-10",
          "scheduled_time" => "14:00:00",
          "customer_reminder_48h_sent_at" => "2099-07-08T14:00:00Z",
          "customer_reminder_sent_at" => "2099-07-09T14:00:00Z"
        })
      end

    far_rows =
      for index <- 0..4 do
        base_row(%{
          "id" => "far-#{index}",
          "scheduled_date" => "2099-07-12",
          "scheduled_time" => "10:00:00"
        })
      end

    items =
      Schedule.select_due_work_items(
        morning_rows ++ far_rows,
        morning_now,
        3,
        @claim_ttl_ms,
        morning_hour: 8,
        morning_tolerance_hours: 2
      )

    assert length(items) == 3
    assert Enum.all?(items, fn item -> item.stage == :customer_morning end)
  end
end
