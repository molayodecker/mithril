defmodule MithrilWeb.OpenApiDocsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  test "docs root serves Swagger UI on the configured docs hostname" do
    conn =
      build_conn()
      |> Map.put(:host, "openapi.example.com")
      |> get("/")

    assert conn.status == 200
    assert conn.resp_body =~ "Swagger UI"
  end

  test "docs root is not exposed on the primary API hostname" do
    conn =
      build_conn()
      |> Map.put(:host, "api.example.com")
      |> get("/")

    assert conn.status == 404
  end

  test "redoc is available under /docs/redoc on any hostname" do
    conn = get(build_conn(), "/docs/redoc")

    assert conn.status == 200
    assert conn.resp_body =~ "redoc"
  end
end
