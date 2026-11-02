defmodule MithrilWeb.Schemas.DirectAdminTeam do
  @moduledoc false

  defmodule Member do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamMember",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        roles: %Schema{type: :array, items: %Schema{type: :string}},
        permissions: %Schema{type: :array, items: %Schema{type: :string}}
      }
    })
  end

  defmodule PermissionCatalogEntry do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamPermissionCatalogEntry",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        label: %Schema{type: :string}
      },
      required: [:id, :label]
    })
  end

  defmodule RoleGuideEntry do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamRoleGuideEntry",
      type: :object,
      properties: %{
        role: %Schema{type: :string, enum: ["admin", "reviewer"]},
        label: %Schema{type: :string},
        access: %Schema{type: :string}
      },
      required: [:role, :label, :access]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminTeam.{Member, PermissionCatalogEntry, RoleGuideEntry}
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamListResponse",
      type: :object,
      properties: %{
        members: %Schema{type: :array, items: Member},
        roleGuide: %Schema{type: :array, items: RoleGuideEntry},
        permissionCatalog: %Schema{type: :array, items: PermissionCatalogEntry}
      },
      required: [:members]
    })
  end

  defmodule UpdateAccessRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamUpdateAccessRequest",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        staffRoles: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ["admin", "reviewer"]}
        },
        permissions: %Schema{type: :array, items: %Schema{type: :string}}
      }
    })
  end

  defmodule GrantRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamGrantRequest",
      type: :object,
      properties: %{
        role: %Schema{type: :string, enum: ["admin", "reviewer"]},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true}
      },
      required: [:role]
    })
  end

  defmodule RevokeRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamRevokeRequest",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        role: %Schema{type: :string, enum: ["admin", "reviewer"]}
      },
      required: [:userId, :role]
    })
  end
end
