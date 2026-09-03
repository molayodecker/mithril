defmodule MithrilWeb.HealthControllerTest do
  use ExUnit.Case, async: true
  use Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  test "GET /health reports the service as healthy" do
    conn = get(build_conn(), "/health")

    assert %{"service" => "mithril", "status" => "ok"} = json_response(conn, 200)
  end
end
