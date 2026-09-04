defmodule MithrilWeb.ReadyControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  @endpoint MithrilWeb.Endpoint

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "GET /ready reports ready when PostgreSQL is reachable" do
    conn = get(build_conn(), "/ready")

    assert %{
             "service" => "mithril",
             "status" => "ready",
             "database" => "ok"
           } = json_response(conn, 200)
  end
end
