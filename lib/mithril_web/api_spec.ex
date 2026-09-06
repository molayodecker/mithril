defmodule MithrilWeb.ApiSpec do
  @behaviour OpenApiSpex.OpenApi

  alias MithrilWeb.{Endpoint, Router}
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Mithril API",
        version: "1.0.0",
        description: "Instaclean backend API contracts."
      },
      paths: Paths.from_router(Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
