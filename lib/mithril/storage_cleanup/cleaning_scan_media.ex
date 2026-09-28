defmodule Mithril.StorageCleanup.CleaningScanMedia do
  @moduledoc false

  @spec interpret_rpc_result(:ok | {:error, term()}) :: :ok | {:error, term()} | :skipped
  def interpret_rpc_result({:ok, _}), do: :ok

  def interpret_rpc_result({:error, %{postgres: %{code: "42883"}}}), do: :skipped

  def interpret_rpc_result({:error, error}), do: {:error, error}
end
