defmodule MithrilWeb.Plugs.OpenApiDocsHost do
  @moduledoc """
  Restricts a route scope to configured OpenAPI documentation hostnames.
  """

  import Plug.Conn

  alias MithrilWeb.OpenApiDocs

  def init(opts), do: opts

  def call(conn, _opts) do
    if OpenApiDocs.docs_host?(conn.host) do
      conn
    else
      conn
      |> send_resp(:not_found, "Not found")
      |> halt()
    end
  end
end
