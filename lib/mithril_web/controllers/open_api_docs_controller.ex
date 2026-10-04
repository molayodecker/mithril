defmodule MithrilWeb.OpenApiDocsController do
  use Phoenix.Controller, formats: [:html]

  @redoc_html """
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Mithril API</title>
      <style>body { margin: 0; padding: 0; }</style>
    </head>
    <body>
      <redoc spec-url="/openapi.json"></redoc>
      <script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
    </body>
  </html>
  """

  def redoc(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(:ok, @redoc_html)
  end
end
