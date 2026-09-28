defmodule Mithril.StorageCleanup.CleaningScanMediaTest do
  use ExUnit.Case, async: true

  alias Mithril.StorageCleanup.CleaningScanMedia

  test "successful rpc returns ok" do
    assert :ok = CleaningScanMedia.interpret_rpc_result({:ok, %{rows: []}})
  end

  test "missing rpc is skipped without error" do
    assert :skipped =
             CleaningScanMedia.interpret_rpc_result({:error, %{postgres: %{code: "42883"}}})
  end

  test "other database errors propagate" do
    assert {:error, error} =
             CleaningScanMedia.interpret_rpc_result({:error, %{postgres: %{code: "23505"}}})

    assert error.postgres.code == "23505"
  end
end
