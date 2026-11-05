defmodule Mithril.Sumsub.TimestampTest do
  use ExUnit.Case, async: true

  alias Mithril.Sumsub.Timestamp

  test "utc_now is a DateTime Postgrex can encode as timestamptz" do
    now = Timestamp.utc_now()
    assert %DateTime{} = now
    assert now.microsecond |> elem(1) <= 6
  end

  test "cast turns the ISO8601 string that crashed token linking into a DateTime" do
    assert %DateTime{year: 2026, month: 11, day: 5, hour: 12, minute: 21, second: 57} =
             Timestamp.cast("2026-11-05T12:21:57.189081Z")
  end

  test "cast keeps an existing database DateTime" do
    existing = ~U[2025-01-01 00:00:00Z]
    assert Timestamp.cast(existing) == existing
  end

  test "cast drops blank timestamps" do
    assert Timestamp.cast("   ") == nil
    assert Timestamp.cast(nil) == nil
  end
end
