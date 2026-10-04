defmodule MithrilWeb.Plugs.OpenApiDocsHostGuard do
  @moduledoc """
  Prevents dedicated OpenAPI documentation hostnames from falling through into
  the normal API router.
  """

  import Plug.Conn

  alias MithrilWeb.OpenApiDocs

  @allowed_paths ["/", "/redoc", "/openapi.json"]

  def init(opts), do: opts

  def call(conn, _opts) do
    if OpenApiDocs.docs_host?(conn.host) and conn.request_path not in @allowed_paths do
      conn
      |> send_resp(:not_found, "Not found")
      |> halt()
    else
      conn
    end
  end
end
