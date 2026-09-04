defmodule MithrilWeb.ReadyControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  test "GET /ready reports ready when PostgreSQL is reachable" do
    conn = get(build_conn(), "/ready")

    assert %{
             "service" => "mithril",
             "status" => "ready",
             "database" => "ok"
           } = json_response(conn, 200)
  end
end
