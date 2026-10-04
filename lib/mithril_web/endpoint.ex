defmodule MithrilWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :mithril

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug MithrilWeb.Plugs.OpenApiDocsCors
  plug MithrilWeb.Plugs.OpenApiDocsHostGuard

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {MithrilWeb.CacheBodyReader, :read_body, []},
    length: 8_000_000

  plug Plug.MethodOverride
  plug Plug.Head

  plug MithrilWeb.Router
end
