defmodule MithrilWeb.Schemas.MobileCalls do
  @moduledoc """
  OpenAPI contracts for named mobile calls that have moved off `POST /mobile/rpc/{name}`.
  """

  alias OpenApiSpex.Operation
  alias OpenApiSpex.Schema

  defmodule ServiceAreaRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileServiceAreaRequest",
      type: :object,
      properties: %{
        p_lat: %Schema{type: :number},
        p_lng: %Schema{type: :number}
      },
      required: [:p_lat, :p_lng]
    })
  end

  defmodule ServiceAreaResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileServiceAreaResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :boolean}
      },
      required: [:data]
    })
  end

  defmodule WalletBalance do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileWalletBalance",
      type: :object,
      properties: %{
        balance: %Schema{type: :integer, description: "Balance in pesewas"},
        currency: %Schema{type: :string}
      },
      required: [:balance, :currency]
    })
  end

  defmodule WalletBalanceResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileWalletBalanceResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MithrilWeb.Schemas.MobileCalls.WalletBalance}
      },
      required: [:data]
    })
  end

  defmodule PricingRule do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobilePricingRule",
      type: :object,
      properties: %{
        pricing_version: %Schema{type: :string},
        currency: %Schema{type: :string},
        same_day_surcharge_bps: %Schema{type: :integer},
        weekend_surcharge_bps: %Schema{type: :integer},
        recurring_weekly_discount_bps: %Schema{type: :integer},
        recurring_monthly_discount_bps: %Schema{type: :integer},
        recurring_discount_bps_by_interval: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :integer},
          nullable: true
        }
      },
      required: [
        :pricing_version,
        :currency,
        :same_day_surcharge_bps,
        :weekend_surcharge_bps,
        :recurring_weekly_discount_bps,
        :recurring_monthly_discount_bps
      ]
    })
  end

  defmodule PricingRuleResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobilePricingRuleResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MithrilWeb.Schemas.MobileCalls.PricingRule}
      },
      required: [:data]
    })
  end

  defmodule ReferralInfo do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileReferralInfo",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        referral_code: %Schema{type: :string},
        referred_count: %Schema{type: :integer},
        already_redeemed: %Schema{type: :boolean},
        discount_percent: %Schema{type: :number},
        offer_eligible: %Schema{type: :boolean},
        offer_role: %Schema{type: :string, enum: ["friend", "host"], nullable: true},
        host_offer_pending: %Schema{type: :boolean}
      },
      required: [:success]
    })
  end

  defmodule ReferralInfoResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileReferralInfoResponse",
      type: :object,
      properties: %{
        data: MithrilWeb.Schemas.MobileCalls.ReferralInfo
      },
      required: [:data]
    })
  end

  defmodule ApplyReferralRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileApplyReferralRequest",
      type: :object,
      properties: %{
        p_code: %Schema{type: :string}
      },
      required: [:p_code]
    })
  end

  defmodule ApplyReferralResult do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileApplyReferralResult",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        referrer_name: %Schema{type: :string, nullable: true},
        error: %Schema{type: :string, nullable: true}
      },
      required: [:success]
    })
  end

  defmodule ApplyReferralResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileApplyReferralResponse",
      type: :object,
      properties: %{
        data: MithrilWeb.Schemas.MobileCalls.ApplyReferralResult
      },
      required: [:data]
    })
  end

  defmodule VerificationService do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileVerificationService",
      type: :object,
      properties: %{
        category_id: %Schema{type: :integer},
        category_name: %Schema{type: :string},
        category_icon: %Schema{type: :string, nullable: true},
        category_slug: %Schema{type: :string, nullable: true},
        service_type_id: %Schema{type: :integer},
        service_type_name: %Schema{type: :string},
        service_category: %Schema{type: :string},
        specialty_slug: %Schema{type: :string, nullable: true},
        price: %Schema{type: :number},
        duration: %Schema{type: :string},
        features: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
        active: %Schema{type: :boolean}
      },
      required: [
        :category_id,
        :category_name,
        :service_type_id,
        :service_type_name,
        :service_category,
        :price,
        :duration,
        :active
      ]
    })
  end

  defmodule VerificationServiceCatalogResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileVerificationServiceCatalogResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MithrilWeb.Schemas.MobileCalls.VerificationService}
      },
      required: [:data]
    })
  end

  def operation({:user_rpc, "is_location_in_active_service_area"}) do
    post("mobile.checkServiceArea", "Whether coordinates are inside the active service area",
      request: ServiceAreaRequest,
      response: ServiceAreaResponse
    )
  end

  def operation({:guest_rpc, "is_location_in_active_service_area"}) do
    post(
      "mobile.checkServiceAreaGuest",
      "Whether coordinates are inside the active service area, without a signed-in user",
      request: ServiceAreaRequest,
      response: ServiceAreaResponse
    )
  end

  def operation({:user_rpc, "get_my_wallet_balance"}) do
    post("mobile.getMyWalletBalance", "Wallet balance for the signed-in user",
      response: WalletBalanceResponse
    )
  end

  def operation({:user_rpc, "get_active_pricing_rule"}) do
    post("mobile.getActivePricingRule", "Active booking pricing rule for the signed-in user",
      response: PricingRuleResponse
    )
  end

  def operation({:guest_rpc, "get_active_pricing_rule"}) do
    post(
      "mobile.getActivePricingRuleGuest",
      "Active booking pricing rule without a signed-in user",
      response: PricingRuleResponse
    )
  end

  def operation({:user_rpc, "get_my_referral_info"}) do
    post("mobile.getMyReferralInfo", "Referral code and offer state for the signed-in user",
      response: ReferralInfoResponse
    )
  end

  def operation({:user_rpc, "apply_referral_code"}) do
    post("mobile.applyReferralCode", "Apply a referral code for the signed-in user",
      request: ApplyReferralRequest,
      response: ApplyReferralResponse
    )
  end

  def operation({:user_rpc, "get_verification_service_catalog"}) do
    post("mobile.getVerificationServiceCatalog", "Services a provider can verify",
      response: VerificationServiceCatalogResponse
    )
  end

  def operation(_other), do: nil

  defp post(operation_id, summary, opts) do
    %Operation{
      tags: ["mobile-calls"],
      operationId: operation_id,
      summary: summary,
      requestBody:
        case opts[:request] do
          nil ->
            nil

          schema ->
            Operation.request_body("Arguments", "application/json", schema, required: true)
        end,
      responses: %{
        200 => Operation.response("Call result", "application/json", opts[:response])
      }
    }
  end
end
