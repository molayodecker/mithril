defmodule MithrilWeb.Plugs.OpenApiDocsCors do
  @moduledoc """
  Allows browser-based OpenAPI docs to call the API without opening CORS to
  arbitrary origins.
  """

  import Plug.Conn

  alias MithrilWeb.OpenApiDocs

  @allow_methods "GET,POST,PUT,PATCH,DELETE,OPTIONS"
  @allow_headers Enum.join(
                   [
                     "authorization",
                     "content-type",
                     "x-mithril-direct-token",
                     "x-instaclean-user-id",
                     "x-mithril-parity-token"
                   ],
                   ","
                 )

  def init(opts), do: opts

  def call(conn, _opts) do
    case allowed_origin(conn) do
      nil ->
        conn

      origin ->
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", @allow_methods)
        |> put_resp_header("access-control-allow-headers", @allow_headers)
        |> put_resp_header("access-control-max-age", "600")
        |> put_resp_header("vary", "Origin")
        |> maybe_finish_preflight()
    end
  end

  defp allowed_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin] ->
        Enum.find(allowed_origins(), &(&1 == origin))

      _ ->
        nil
    end
  end

  defp allowed_origins do
    Enum.map(OpenApiDocs.hosts(), &"https://#{&1}")
  end

  defp maybe_finish_preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(:no_content, "")
    |> halt()
  end

  defp maybe_finish_preflight(conn), do: conn
end
