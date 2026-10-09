defmodule MithrilWeb.Schemas.DirectAdminServiceAreas do
  @moduledoc "OpenAPI schemas for Direct admin service areas."

  defmodule ServiceArea do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceArea",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        country: %Schema{type: :string},
        active: %Schema{type: :boolean},
        cleanerCount: %Schema{type: :integer}
      },
      required: [:id, :name, :country, :active, :cleanerCount]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminServiceAreas.ServiceArea
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceAreaListResponse",
      type: :object,
      properties: %{areas: %Schema{type: :array, items: ServiceArea}},
      required: [:areas]
    })
  end
end
