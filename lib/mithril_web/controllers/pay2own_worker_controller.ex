defmodule MithrilWeb.Pay2OwnWorkerController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Pay2Own

  def lookup(conn, params) do
    case Pay2Own.account?(params) do
      {:ok, account} -> json(conn, %{account: account})
      {:error, _reason} -> conn |> put_status(503) |> json(%{error: "lookup_unavailable"})
    end
  end
end
