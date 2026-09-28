defmodule Mithril.AdminBroadcast.BatchWorkerTest do
  use ExUnit.Case, async: true

  alias Mithril.AdminBroadcast.{Delivery, Progress}
  alias Mithril.Workers.AdminBroadcastBatch

  test "Oban child worker enqueues bounded batches by broadcast id" do
    assert Delivery.batch_size() == 50
    assert {:enqueue, 1} in AdminBroadcastBatch.__info__(:functions)
  end

  test "retries advance offset without reprocessing prior recipients" do
    recipient_ids = for index <- 1..75, do: "user-#{index}"

    {batch1, offset1, _} = Progress.next_batch(recipient_ids, 0, 50)
    {batch2, offset2, done?} = Progress.next_batch(recipient_ids, offset1, 50)

    assert length(batch1) == 50
    assert length(batch2) == 25
    assert offset2 == 75
    assert done?

    assert MapSet.disjoint?(MapSet.new(batch1), MapSet.new(batch2))
  end

  test "partial batch stats merge preserves prior progress counters" do
    base = Delivery.parse_stats(%{"inAppCreated" => 2, "attempted" => 2})

    delta = %{
      "fetched" => 1,
      "skippedPrefs" => 0,
      "attempted" => 1,
      "inAppCreated" => 1,
      "pushDevicesSent" => 0,
      "smsSent" => 0,
      "whatsappSent" => 0,
      "failed" => 0
    }

    {merged, new_offset, done?, status} =
      Progress.merge_progress(base, delta, 50, Enum.map(1..60, &"u#{&1}"), 50)

    assert merged["inAppCreated"] == 3
    assert merged["attempted"] == 3
    assert new_offset == 60
    assert done?
    assert status == "completed"
  end
end
