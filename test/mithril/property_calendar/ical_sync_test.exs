defmodule Mithril.PropertyCalendar.IcalSyncTest do
  use ExUnit.Case, async: true

  alias Mithril.PropertyCalendar.IcalSync

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Mithril.Repo)
    :ok
  end

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

  test "Postgrex encodes typed local calendar timestamps for timezone conversion" do
    assert {:ok, %{rows: [[converted]]}} =
             Mithril.Repo.query(
               "SELECT COALESCE($1::timestamptz, $2::timestamp AT TIME ZONE $3::text)",
               [nil, ~N[2026-10-10 15:00:00], "Africa/Accra"]
             )

    assert DateTime.compare(converted, ~U[2026-10-10 15:00:00Z]) == :eq

    assert {:ok, %{rows: [[utc_converted]]}} =
             Mithril.Repo.query(
               "SELECT COALESCE($1::timestamptz, $2::timestamp AT TIME ZONE $3::text)",
               [~U[2026-10-10 15:00:00Z], nil, "Africa/Accra"]
             )

    assert DateTime.compare(utc_converted, ~U[2026-10-10 15:00:00Z]) == :eq
  end

  test "all-day events apply check-in to DTSTART and checkout to DTEND" do
    event = %{
      dtstart: %{kind: "date", date_part: "20261010"},
      dtend: %{kind: "date", date_part: "20261012"}
    }

    feed = %{
      "default_checkin_time" => "15:00:00",
      "default_checkout_time" => "11:00:00"
    }

    assert {:ok, {starts_at, ends_at}} = IcalSync.resolve_window_for_test(event, feed)

    assert starts_at == %{utc: nil, local: ~N[2026-10-10 15:00:00]}
    assert ends_at == %{utc: nil, local: ~N[2026-10-12 11:00:00]}
  end

  test "invalid calendar dates are rejected without raising" do
    event = %{
      dtstart: %{kind: "utc", date_part: "20260230", time_part: "150000"},
      dtend: %{kind: "utc", date_part: "20260301", time_part: "110000"}
    }

    assert {:error, "Invalid calendar event datetime"} =
             IcalSync.resolve_window_for_test(event, %{})
  end
end
