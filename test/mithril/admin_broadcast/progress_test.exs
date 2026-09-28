defmodule Mithril.AdminBroadcast.ProgressTest do
  use ExUnit.Case, async: true

  alias Mithril.AdminBroadcast.Progress

  test "next_batch slices without loading entire audience at once" do
    recipient_ids = for index <- 1..120, do: "user-#{index}"

    {batch1, offset1, done1} = Progress.next_batch(recipient_ids, 0, 50)
    assert length(batch1) == 50
    assert offset1 == 50
    refute done1

    {batch2, offset2, done2} = Progress.next_batch(recipient_ids, offset1, 50)
    assert length(batch2) == 50
    assert offset2 == 100
    refute done2

    {batch3, offset3, done3} = Progress.next_batch(recipient_ids, offset2, 50)
    assert length(batch3) == 20
    assert offset3 == 120
    assert done3
  end

  test "merge_progress marks completed when any channel delivered" do
    stats = %{
      "fetched" => 1,
      "skippedPrefs" => 0,
      "attempted" => 1,
      "inAppCreated" => 1,
      "pushDevicesSent" => 0,
      "smsSent" => 0,
      "whatsappSent" => 0,
      "failed" => 0
    }

    {merged, new_offset, done?, final_status} =
      Progress.merge_progress(%{}, stats, 0, ["a"], 50)

    assert done?
    assert final_status == "completed"
    assert merged["inAppCreated"] == 1
    assert new_offset == 1
  end

  test "only queued or sending broadcasts are eligible for worker pickup" do
    assert Progress.should_enqueue?("queued")
    assert Progress.should_enqueue?("sending")
    refute Progress.should_enqueue?("completed")
    refute Progress.should_enqueue?("failed")
  end
end
