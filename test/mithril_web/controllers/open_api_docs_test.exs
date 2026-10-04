defmodule MithrilWeb.OpenApiDocsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

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

  test "docs hostname cannot fall through to API routes" do
    conn =
      build_conn()
      |> Map.put(:host, "openapi.example.com")
      |> get("/auth/methods")

    assert conn.status == 404
  end

  test "docs hostname still serves the OpenAPI contract" do
    conn =
      build_conn()
      |> Map.put(:host, "openapi.example.com")
      |> get("/openapi.json")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
  end

  test "API preflight allows the configured docs origin" do
    conn =
      build_conn()
      |> Map.put(:host, "api.example.com")
      |> put_req_header("origin", "https://openapi.example.com")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "authorization,content-type")
      |> options("/direct/bookings")

    assert conn.status == 204

    assert get_resp_header(conn, "access-control-allow-origin") == [
             "https://openapi.example.com"
           ]

    assert "authorization" in (get_resp_header(conn, "access-control-allow-headers")
                               |> List.first()
                               |> String.downcase()
                               |> String.split(",", trim: true)
                               |> Enum.map(&String.trim/1))
  end

  test "API responses expose CORS only to configured docs origins" do
    allowed =
      build_conn()
      |> Map.put(:host, "api.example.com")
      |> put_req_header("origin", "https://openapi.example.com")
      |> get("/health")

    assert get_resp_header(allowed, "access-control-allow-origin") == [
             "https://openapi.example.com"
           ]

    denied =
      build_conn()
      |> Map.put(:host, "api.example.com")
      |> put_req_header("origin", "https://evil.example.com")
      |> get("/health")

    assert get_resp_header(denied, "access-control-allow-origin") == []
  end

  test "OpenAPI contract declares auth schemes and applies them to secured operations" do
    spec = MithrilWeb.ApiSpec.spec()

    assert %OpenApiSpex.SecurityScheme{type: "http", scheme: "bearer"} =
             spec.components.securitySchemes["bearerAuth"]

    direct = spec.paths["/direct/bookings"].post

    assert %{"bearerAuth" => []} in direct.security
    assert %{"directToken" => [], "directUserId" => []} in direct.security

    refute Map.has_key?(spec.paths, "/auth/login")
  end
end
