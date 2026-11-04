defmodule Mithril.StorageCleanup.CleaningScanMedia do
  @moduledoc false

  @spec interpret_rpc_result({:ok, term()} | {:error, term()}) ::
          :ok | :skipped | {:error, term()}
  def interpret_rpc_result({:ok, _}), do: :ok

  # Postgrex reports a missing function as code: :undefined_function and
  # pg_code: "42883". Older callers matched the SQLSTATE string on code.
  def interpret_rpc_result({:error, %{postgres: %{code: code}}})
      when code in [:undefined_function, "42883"],
      do: :skipped

  def interpret_rpc_result({:error, %{postgres: %{pg_code: "42883"}}}), do: :skipped

  def interpret_rpc_result({:error, error}), do: {:error, error}
end
