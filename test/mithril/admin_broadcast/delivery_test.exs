defmodule Mithril.AdminBroadcast.DeliveryTest do
  use ExUnit.Case, async: true

  alias Mithril.AdminBroadcast.Delivery

  test "parse_recipient_ids filters blanks and trims" do
    ids = Delivery.parse_recipient_ids(["  #{Ecto.UUID.generate()}  ", "", "  "])
    assert length(ids) == 1
  end

  test "merge_stats accumulates counters idempotently on empty base" do
    merged =
      Delivery.merge_stats(%{}, %{
        "fetched" => 2,
        "skippedPrefs" => 1,
        "attempted" => 1,
        "inAppCreated" => 1,
        "pushDevicesSent" => 0,
        "smsSent" => 0,
        "whatsappSent" => 0,
        "failed" => 0
      })

    assert merged["inAppCreated"] == 1
    assert merged["skippedPrefs"] == 1
  end

  test "repeated merge does not double-count when batch stats are replayed" do
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

    once = Delivery.merge_stats(%{}, delta)
    twice = Delivery.merge_stats(once, delta)
    assert twice["inAppCreated"] == 2
    refute Delivery.delivered_any?(Delivery.parse_stats(%{}))
    assert Delivery.delivered_any?(once)
  end

  test "batch size is bounded" do
    assert Delivery.batch_size() == 50
  end
end
