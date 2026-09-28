defmodule Mithril.PropertyCalendar.IcalParserTest do
  use ExUnit.Case, async: true

  alias Mithril.PropertyCalendar.IcalParser

  @sample_ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:evt-1@airbnb
  SEQUENCE:1
  SUMMARY:Guest stay
  DTSTART;VALUE=DATE:20260304
  DTEND;VALUE=DATE:20260306
  END:VEVENT
  BEGIN:VEVENT
  UID:evt-2@airbnb
  SEQUENCE:0
  STATUS:CANCELLED
  DTSTART;VALUE=DATE:20260310
  DTEND;VALUE=DATE:20260312
  END:VEVENT
  END:VCALENDAR
  """

  test "parses duplicate uid events as separate entries before upsert dedupe" do
    assert {:ok, events} = IcalParser.parse_events(@sample_ics)
    assert length(events) == 2
    assert Enum.any?(events, &(&1.uid == "evt-1@airbnb"))
    assert Enum.any?(events, &(&1.uid == "evt-2@airbnb"))
  end

  test "malformed iCal is rejected" do
    assert {:error, message} = IcalParser.parse_events("not a calendar")
    assert message =~ "Invalid"
  end
end
