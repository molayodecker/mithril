defmodule MithrilWeb.OpenApiTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  test "GET /openapi.json exposes the Direct API contract" do
    conn = get(build_conn(), "/openapi.json")
    spec = json_response(conn, 200)

    assert spec["openapi"] =~ "3."
    assert spec["paths"]["/direct/placements"]["get"]
    assert spec["paths"]["/direct/placements"]["post"]
    assert spec["paths"]["/direct/admin/placements/{id}/matches"]["post"]
    assert spec["components"]["schemas"]["DirectCreatePlacementRequest"]
    assert spec["components"]["schemas"]["DirectPlacementDetailResponse"]
  end
end
