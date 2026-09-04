defmodule Mithril.DatabaseBackendTest do
  use ExUnit.Case, async: true

  alias Mithril.DatabaseBackend

  defp env(map) do
    fn key -> Map.get(map, key) end
  end

  test "defaults to supabase DATABASE_URL" do
    assert {"supabase", "postgresql://supabase"} =
             DatabaseBackend.resolve(env(%{"DATABASE_URL" => "postgresql://supabase"}))
  end

  test "prefers SUPABASE_DATABASE_URL over DATABASE_URL" do
    assert {"supabase", "postgresql://named-supabase"} =
             DatabaseBackend.resolve(
               env(%{
                 "DATABASE_BACKEND" => "supabase",
                 "SUPABASE_DATABASE_URL" => "postgresql://named-supabase",
                 "DATABASE_URL" => "postgresql://legacy",
                 "FLY_DATABASE_URL" => "postgresql://fly"
               })
             )
  end

  test "selects FLY_DATABASE_URL when DATABASE_BACKEND=fly" do
    assert {"fly", "postgresql://fly"} =
             DatabaseBackend.resolve(
               env(%{
                 "DATABASE_BACKEND" => "fly",
                 "FLY_DATABASE_URL" => "postgresql://fly",
                 "SUPABASE_DATABASE_URL" => "postgresql://supabase",
                 "DATABASE_URL" => "postgresql://legacy"
               })
             )
  end

  test "resolve! requires the active backend URL" do
    assert_raise ArgumentError, ~r/FLY_DATABASE_URL/, fn ->
      DatabaseBackend.resolve!(env(%{"DATABASE_BACKEND" => "fly"}))
    end
  end

  test "rejects unknown backends" do
    assert_raise ArgumentError, ~r/fly" or "supabase/, fn ->
      DatabaseBackend.resolve(env(%{"DATABASE_BACKEND" => "neon"}))
    end
  end
end
