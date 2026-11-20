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
        status: %Schema{
          type: :string,
          enum: ["active", "scheduled", "expired", "inactive", "exhausted"]
        },
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

  defmodule Offer do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPromotion",
      type: :object,
      description: "An active promotion concierge can attach to a booking.",
      properties: %{
        slug: %Schema{type: :string},
        headline: %Schema{type: :string},
        type: %Schema{type: :string},
        value: %Schema{type: :number},
        channel: %Schema{type: :string},
        requiresNewCustomer: %Schema{type: :boolean},
        maxDurationHours: %Schema{type: :number, nullable: true}
      },
      required: [:slug, :headline, :type, :value, :channel, :requiresNewCustomer]
    })
  end

  defmodule OfferList do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminPromotions.Offer
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPromotionList",
      type: :object,
      properties: %{promotions: %Schema{type: :array, items: Offer}},
      required: [:promotions]
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
