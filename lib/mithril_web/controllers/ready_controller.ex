defmodule MithrilWeb.ReadyController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Repo

  @query_timeout 1_000

  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: @query_timeout) do
      {:ok, _result} ->
        json(conn, %{service: "mithril", status: "ready", database: "ok"})

      {:error, _reason} ->
        unavailable(conn)
    end
  catch
    :exit, _reason -> unavailable(conn)
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{service: "mithril", status: "not_ready", database: "unavailable"})
  end
end
