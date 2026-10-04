defmodule MithrilWeb.ApiSpec do
  @behaviour OpenApiSpex.OpenApi

  alias MithrilWeb.{Endpoint, Router}

  alias OpenApiSpex.{
    Components,
    Info,
    OpenApi,
    Operation,
    Paths,
    SecurityScheme,
    Server
  }

  @http_verbs [:get, :put, :post, :delete, :options, :head, :patch, :trace]

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Mithril API",
        version: "1.0.0",
        description: "Instaclean backend API contracts."
      },
      components: %Components{securitySchemes: security_schemes()},
      paths: Router |> Paths.from_router() |> add_security_requirements()
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp security_schemes do
    %{
      "bearerAuth" => %SecurityScheme{
        type: "http",
        scheme: "bearer",
        bearerFormat: "JWT",
        description: "Mithril access token returned by the authentication endpoints."
      },
      "directToken" => %SecurityScheme{
        type: "apiKey",
        in: "header",
        name: "x-mithril-direct-token",
        description: "Direct gateway token for trusted server-to-server clients."
      },
      "directUserId" => %SecurityScheme{
        type: "apiKey",
        in: "header",
        name: "x-instaclean-user-id",
        description: "Active Instaclean user UUID used with the Direct gateway token."
      },
      "parityToken" => %SecurityScheme{
        type: "apiKey",
        in: "header",
        name: "x-mithril-parity-token",
        description: "Temporary migration-parity token."
      }
    }
  end

  defp add_security_requirements(paths) do
    Map.new(paths, fn {path, path_item} ->
      {path,
       Enum.reduce(@http_verbs, path_item, fn verb, item ->
         case Map.get(item, verb) do
           %Operation{} = operation ->
             Map.put(item, verb, %{operation | security: security_for_path(path)})

           _ ->
             item
         end
       end)}
    end)
  end

  # A Direct request may authenticate with a normal Mithril bearer token OR with
  # the trusted gateway token + explicit user-id pair.
  defp security_for_path("/direct/" <> _rest) do
    [
      %{"bearerAuth" => []},
      %{"directToken" => [], "directUserId" => []}
    ]
  end

  defp security_for_path("/mobile/" <> _rest), do: [%{"bearerAuth" => []}]
  defp security_for_path("/internal/parity/" <> _rest), do: [%{"parityToken" => []}]

  defp security_for_path(path)
       when path in [
              "/auth/me",
              "/auth/cleaner-activation-status",
              "/auth/password"
            ],
       do: [%{"bearerAuth" => []}]

  defp security_for_path("/bookings/{id}/transport-estimate"), do: [%{"bearerAuth" => []}]

  # Public auth, health, webhook and browser-return endpoints remain explicitly
  # unauthenticated in the contract.
  defp security_for_path(_path), do: []
end
