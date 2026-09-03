defmodule MithrilWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    json(conn, %{service: "mithril", status: "ok"})
  end
end
