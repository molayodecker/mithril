defmodule Mithril.SqlTimeTest do
  use ExUnit.Case, async: true

  alias Mithril.SqlTime

  test "parses SQL time values with or without seconds" do
    assert {:ok, ~T[06:00:00]} = SqlTime.parse("06:00")
    assert {:ok, ~T[06:00:30]} = SqlTime.parse("06:00:30")
    assert {:ok, ~T[06:00:00]} = SqlTime.parse(" 06:00 ")
    assert {:ok, ~T[06:00:00]} = SqlTime.parse(~T[06:00:00])
  end

  test "rejects malformed or out-of-range time values" do
    assert {:error, _} = SqlTime.parse("25:00")
    assert {:error, _} = SqlTime.parse("06:99")
    assert {:error, _} = SqlTime.parse("tomorrow")
    assert {:error, _} = SqlTime.parse(nil)
  end
end
