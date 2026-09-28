defmodule Mithril.PropertyCalendar.IcalSyncTest do
  use ExUnit.Case, async: true

  alias Mithril.PropertyCalendar.IcalSync

  test "apply_incoming_event? rejects stale sequence updates" do
    existing = %{sequence: 3, raw_event_hash: "abc"}

    refute IcalSync.apply_incoming_event?(existing, 2, "def")
    assert IcalSync.apply_incoming_event?(existing, 4, "def")
  end

  test "apply_incoming_event? skips identical payload without sequence" do
    existing = %{sequence: nil, raw_event_hash: "same-hash"}
    refute IcalSync.apply_incoming_event?(existing, nil, "same-hash")
    assert IcalSync.apply_incoming_event?(existing, nil, "other-hash")
  end

  test "temporary empty feed does not pass credibility check when prior events exist" do
    assert {:error, message} = IcalSync.credible_after_parse?([], 2)
    assert message =~ "zero events"
    assert :ok = IcalSync.credible_after_parse?([], 0)
  end

  test "missing sync threshold requires consecutive misses before cancel" do
    assert IcalSync.missing_sync_threshold() == 3
  end
end
