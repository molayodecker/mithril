defmodule MithrilWeb.Schemas.DirectAdminServices do
  @moduledoc "OpenAPI schemas for Direct admin service catalog."

  defmodule Service do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminService",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string},
        categoryId: %Schema{type: :integer, nullable: true},
        categoryName: %Schema{type: :string, nullable: true},
        categorySlug: %Schema{type: :string, nullable: true},
        description: %Schema{type: :string, nullable: true},
        priceGhs: %Schema{type: :number},
        active: %Schema{type: :boolean},
        minimumDurationHours: %Schema{type: :number},
        maximumDurationHours: %Schema{type: :number},
        specialtySlug: %Schema{type: :string, nullable: true},
        weight: %Schema{type: :integer}
      },
      required: [:id, :name, :priceGhs, :active]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminServices.Service
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceListResponse",
      type: :object,
      properties: %{services: %Schema{type: :array, items: Service}},
      required: [:services]
    })
  end

  defmodule ServiceResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminServices.Service

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceResponse",
      type: :object,
      properties: %{service: Service},
      required: [:service]
    })
  end

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceUpdateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        priceGhs: %Schema{type: :number},
        active: %Schema{type: :boolean},
        minimumDurationHours: %Schema{type: :number},
        maximumDurationHours: %Schema{type: :number}
      }
    })
  end
end
