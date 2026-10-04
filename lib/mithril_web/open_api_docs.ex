defmodule MithrilWeb.OpenApiDocs do
  @moduledoc """
  Hostnames that serve the public OpenAPI documentation site (Swagger UI + Redoc).

  API traffic stays on `api.tryinstaclean.com` / `dev.tryinstaclean.com`; docs hosts
  only expose `/`, `/redoc`, and `/openapi.json`.
  """

  @default_hosts [
    "openapi.tryinstaclean.com",
    "openapi-stage.tryinstaclean.com"
  ]

  def hosts do
    case Application.get_env(:mithril, :open_api_docs_hosts) do
      hosts when is_list(hosts) and hosts != [] -> hosts
      _ -> @default_hosts
    end
  end

  def docs_host?(host) when is_binary(host) do
    normalized = String.downcase(host)
    Enum.any?(hosts(), &(String.downcase(&1) == normalized))
  end
end
