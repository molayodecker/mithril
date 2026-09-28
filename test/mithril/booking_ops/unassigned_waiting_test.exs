defmodule Mithril.BookingOps.UnassignedWaitingTest do
  use ExUnit.Case, async: true

  alias Mithril.BookingOps.UnassignedWaiting

  test "first notice due after waiting window from updated_at" do
    now = ~U[2024-11-15 12:00:00.000000Z]
    now_ms = DateTime.to_unix(now, :millisecond)
    updated = now |> DateTime.add(-61, :minute) |> DateTime.to_iso8601()

    row = %{
      "updated_at" => updated,
      "ops_unassigned_paid_notice_sent_at" => nil
    }

    assert UnassignedWaiting.notice_due?(row, 60, now_ms)
  end

  test "repeat notice uses last sent timestamp" do
    now = ~U[2024-11-15 12:00:00.000000Z]
    now_ms = DateTime.to_unix(now, :millisecond)
    last_sent = now |> DateTime.add(-61, :minute) |> DateTime.to_iso8601()

    row = %{
      "updated_at" => last_sent,
      "ops_unassigned_paid_notice_sent_at" => last_sent
    }

    assert UnassignedWaiting.repeat_notice?(row)
    assert UnassignedWaiting.notice_due?(row, 60, now_ms)
  end
end
