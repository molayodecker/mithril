defmodule MithrilWeb.Schemas.MobileAppUpdatePolicy do
  @moduledoc "OpenAPI schema for the guest store-update policy read."

  defmodule Policy do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MobileAppUpdatePolicy",
      type: :object,
      properties: %{
        app: %Schema{type: :string, enum: ["customer", "worker"]},
        channel: %Schema{type: :string, enum: ["production", "preview"]},
        min_version: %Schema{type: :string, example: "1.8.1"},
        recommended_version: %Schema{type: :string, nullable: true, example: "1.8.2"},
        required_message: %Schema{type: :string},
        recommended_message: %Schema{type: :string, nullable: true}
      },
      required: [:app, :channel, :min_version, :required_message]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias MithrilWeb.Schemas.MobileAppUpdatePolicy.Policy
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MobileAppUpdatePolicyResponse",
      description:
        "Maybe-single policy. data is the one matching row, or null when that app has no row.",
      type: :object,
      properties: %{
        data: %Schema{allOf: [Policy], nullable: true}
      },
      required: [:data]
    })
  end
end
