defmodule Mithril.PropertyCalendar.ReconciliationTest do
  use ExUnit.Case, async: true

  alias Mithril.PropertyCalendar.IcalParser
  alias Mithril.PropertyCalendar.IcalSync

  @changed_sequence """
  BEGIN:VCALENDAR
  BEGIN:VEVENT
  UID:stay-1@host
  SEQUENCE:2
  SUMMARY:Updated guest
  DTSTART;VALUE=DATE:20260401
  DTEND;VALUE=DATE:20260403
  END:VEVENT
  END:VCALENDAR
  """

  test "duplicate uid in feed is parsed as one logical event row before upsert" do
    ics = """
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:dup@host
    SEQUENCE:0
    DTSTART;VALUE=DATE:20260401
    DTEND;VALUE=DATE:20260402
    END:VEVENT
    END:VCALENDAR
    """

    assert {:ok, [event]} = IcalParser.parse_events(ics)
    assert event.uid == "dup@host"
  end

  test "changed remote sequence is accepted for upsert" do
    existing = %{sequence: 1, raw_event_hash: "old-hash"}
    assert IcalSync.apply_incoming_event?(existing, 2, "new-hash")
  end

  test "removed remote event uses missing sync threshold before cancel" do
    assert IcalSync.missing_sync_threshold() == 3
  end

  test "temporary empty feed fails credibility when prior events existed" do
    assert {:error, _} = IcalSync.credible_after_parse?([], 1)
    assert :ok = IcalSync.credible_after_parse?([], 0)
  end

  test "stale sequence updates are ignored while newer sequence applies" do
    existing = %{sequence: 3, raw_event_hash: "hash-a"}
    refute IcalSync.apply_incoming_event?(existing, 2, "hash-b")
    assert IcalSync.apply_incoming_event?(existing, 4, "hash-b")
  end

  test "identical payload without sequence is ignored" do
    existing = %{sequence: nil, raw_event_hash: "same"}
    refute IcalSync.apply_incoming_event?(existing, nil, "same")
  end

  test "normal feed parses events for sync" do
    assert {:ok, events} = IcalParser.parse_events(@changed_sequence)
    assert hd(events).uid == "stay-1@host"
    assert hd(events).sequence == 2
  end
end
