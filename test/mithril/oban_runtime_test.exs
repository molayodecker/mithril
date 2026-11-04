defmodule Mithril.ObanRuntimeTest do
  use ExUnit.Case, async: true

  alias Mithril.ObanRuntime

  test "starts Oban when the jobs table is present" do
    assert ObanRuntime.classify({:ok, %{rows: [["oban_jobs"]]}}) == :ready
    assert ObanRuntime.classify({:ok, %{rows: [["public.oban_jobs"]]}}) == :ready
  end

  test "skips Oban when the jobs table is absent" do
    assert ObanRuntime.classify({:ok, %{rows: [[nil]]}}) == :missing
    assert ObanRuntime.classify({:ok, %{rows: []}}) == :missing
    assert ObanRuntime.classify({:ok, %{rows: nil}}) == :missing
  end

  test "starts Oban when the schema check cannot be completed" do
    assert ObanRuntime.classify({:error, :database_unavailable}) == :unknown
    assert ObanRuntime.classify(:timeout) == :unknown
  end
end
