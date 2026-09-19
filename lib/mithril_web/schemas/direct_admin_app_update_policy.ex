defmodule MithrilWeb.Schemas.DirectAdminAppUpdatePolicy do
  @moduledoc "OpenAPI schemas for Direct admin app update policy."

  defmodule Policy do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAppUpdatePolicy",
      type: :object,
      properties: %{
        channel: %Schema{type: :string, enum: ["production", "preview"]},
        minVersion: %Schema{type: :string, example: "1.5.30"},
        recommendedVersion: %Schema{type: :string, nullable: true, example: "1.5.31"},
        requiredMessage: %Schema{type: :string},
        recommendedMessage: %Schema{type: :string, nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:channel, :minVersion, :requiredMessage, :updatedAt]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminAppUpdatePolicy.Policy
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAppUpdatePolicyListResponse",
      type: :object,
      properties: %{policies: %Schema{type: :array, items: Policy}},
      required: [:policies]
    })
  end

  defmodule SaveRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAppUpdatePolicySaveRequest",
      type: :object,
      properties: %{
        channel: %Schema{type: :string, enum: ["production", "preview"]},
        minVersion: %Schema{type: :string, example: "1.5.30"},
        recommendedVersion: %Schema{type: :string, nullable: true, example: "1.5.31"},
        requiredMessage: %Schema{type: :string, maxLength: 500},
        recommendedMessage: %Schema{type: :string, nullable: true, maxLength: 500}
      },
      required: [:channel, :minVersion, :requiredMessage]
    })
  end

  defmodule SaveResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminAppUpdatePolicy.Policy

    OpenApiSpex.schema(%{
      title: "DirectAdminAppUpdatePolicySaveResponse",
      type: :object,
      properties: %{policy: Policy},
      required: [:policy]
    })
  end
end
