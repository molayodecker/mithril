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
        roles: %Schema{type: :array, items: %Schema{type: :string}}
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminTeam.Member
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTeamListResponse",
      type: :object,
      properties: %{
        members: %Schema{type: :array, items: Member},
        roleGuide: %Schema{type: :array, items: %Schema{type: :object}}
      },
      required: [:members]
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
