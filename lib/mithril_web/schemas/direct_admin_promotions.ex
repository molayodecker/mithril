defmodule MithrilWeb.Schemas.DirectAdminPromotions do
  @moduledoc "OpenAPI schemas for Direct admin promotion codes."

  defmodule PromotionCode do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPromotionCode",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        code: %Schema{type: :string},
        active: %Schema{type: :boolean},
        status: %Schema{type: :string, enum: ["active", "scheduled", "expired", "inactive"]},
        headline: %Schema{type: :string},
        promotionType: %Schema{type: :string},
        promotionValue: %Schema{type: :integer},
        redemptionCount: %Schema{type: :integer},
        maxRedemptions: %Schema{type: :integer, nullable: true},
        validFrom: %Schema{type: :string, format: :"date-time", nullable: true},
        validTo: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :code, :active, :status, :headline]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminPromotions.PromotionCode
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPromotionCodeListResponse",
      type: :object,
      properties: %{codes: %Schema{type: :array, items: PromotionCode}},
      required: [:codes]
    })
  end
end
