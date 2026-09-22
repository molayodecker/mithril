defmodule Mithril.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @sumsub_env_vars ["SUMSUB_WORKER_LEVEL_NAME", "SUMSUB_LEVEL_NAME"]

  setup do
    original_env =
      Map.new(@sumsub_env_vars, fn name ->
        {name, System.get_env(name)}
      end)

    on_exit(fn ->
      Enum.each(original_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(@sumsub_env_vars, &System.delete_env/1)
    :ok
  end

  test "worker level overrides the legacy alias when both are set" do
    System.put_env("SUMSUB_WORKER_LEVEL_NAME", "worker-level")
    System.put_env("SUMSUB_LEVEL_NAME", "legacy-level")

    assert runtime_sumsub_level_name() == "worker-level"
  end

  test "blank worker level falls back to the legacy alias" do
    System.put_env("SUMSUB_WORKER_LEVEL_NAME", "   ")
    System.put_env("SUMSUB_LEVEL_NAME", "legacy-level")

    assert runtime_sumsub_level_name() == "legacy-level"
  end

  test "configured level names are trimmed" do
    System.put_env("SUMSUB_WORKER_LEVEL_NAME", "  id-and-liveness  ")

    assert runtime_sumsub_level_name() == "id-and-liveness"
  end

  defp runtime_sumsub_level_name do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :test)
    |> Keyword.fetch!(:mithril)
    |> Keyword.fetch!(:sumsub_level_name)
  end
end
