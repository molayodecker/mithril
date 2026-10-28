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

  defmodule LocationTimeRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileLocationTimeRequest",
      type: :object,
      properties: %{
        p_timezone: %Schema{type: :string},
        p_duration_hours: %Schema{type: :number}
      },
      required: [:p_timezone, :p_duration_hours]
    })
  end

  defmodule LocationTime do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileLocationTime",
      type: :object,
      properties: %{
        current_timestamp_tz: %Schema{type: :string, nullable: true},
        local_date: %Schema{type: :string, nullable: true},
        local_time: %Schema{type: :string, nullable: true},
        latest_start_time: %Schema{type: :string, nullable: true},
        same_day_cutoff_at: %Schema{type: :string, nullable: true},
        is_past_day_cutoff: %Schema{type: :boolean, nullable: true},
        is_today_impossible: %Schema{type: :boolean, nullable: true}
      }
    })
  end

  defmodule LocationTimeResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileLocationTimeResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MithrilWeb.Schemas.MobileCalls.LocationTime}
      },
      required: [:data]
    })
  end

  defmodule AvailableTimeslotsRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileAvailableTimeslotsRequest",
      type: :object,
      properties: %{
        p_booking_date: %Schema{type: :string},
        p_timezone: %Schema{type: :string},
        p_duration_hours: %Schema{type: :number},
        p_exclude_booking_id: %Schema{type: :string, nullable: true}
      },
      required: [:p_booking_date, :p_timezone, :p_duration_hours]
    })
  end

  defmodule AvailableTimeslot do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileAvailableTimeslot",
      type: :object,
      properties: %{
        time_12h: %Schema{type: :string, nullable: true},
        time_24h: %Schema{type: :string, nullable: true},
        is_meta_row: %Schema{type: :boolean, nullable: true},
        disable_same_day_booking: %Schema{type: :boolean, nullable: true},
        duration_hours: %Schema{type: :number, nullable: true},
        same_day_cutoff: %Schema{type: :number, nullable: true},
        slot_interval_minutes: %Schema{type: :number, nullable: true},
        travel_buffer: %Schema{type: :number, nullable: true},
        work_day_end: %Schema{type: :number, nullable: true},
        work_day_start: %Schema{type: :number, nullable: true}
      }
    })
  end

  defmodule AvailableTimeslotsResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileAvailableTimeslotsResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MithrilWeb.Schemas.MobileCalls.AvailableTimeslot}
      },
      required: [:data]
    })
  end

  defmodule ValidateTimeslotRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileValidateTimeslotRequest",
      type: :object,
      properties: %{
        p_start_time_12h: %Schema{type: :string},
        p_duration_hours: %Schema{type: :number},
        p_booking_date: %Schema{type: :string},
        p_timezone: %Schema{type: :string, nullable: true}
      },
      required: [:p_start_time_12h, :p_duration_hours, :p_booking_date]
    })
  end

  defmodule ValidateTimeslotResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileValidateTimeslotResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :boolean}
      },
      required: [:data]
    })
  end

  defmodule TimezoneRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileTimezoneRequest",
      type: :object,
      properties: %{
        lat: %Schema{type: :number},
        lng: %Schema{type: :number}
      },
      required: [:lat, :lng]
    })
  end

  defmodule TimezoneResult do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileTimezoneResult",
      type: :object,
      properties: %{
        timezone: %Schema{type: :string},
        name: %Schema{type: :string, nullable: true}
      },
      required: [:timezone]
    })
  end

  defmodule TimezoneResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileTimezoneResponse",
      type: :object,
      properties: %{
        data: MithrilWeb.Schemas.MobileCalls.TimezoneResult
      },
      required: [:data]
    })
  end

  defmodule ExtraTaskLaborRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileExtraTaskLaborRequest",
      type: :object,
      properties: %{
        p_service_id: %Schema{type: :integer},
        p_cleaner_id: %Schema{type: :string, nullable: true},
        p_task_ids: %Schema{type: :array, items: %Schema{type: :string}, nullable: true}
      },
      required: [:p_service_id]
    })
  end

  defmodule ExtraTaskLaborQuote do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileExtraTaskLaborQuote",
      type: :object,
      properties: %{
        task_id: %Schema{type: :string},
        labor_major: %Schema{type: :number},
        pricing_mode: %Schema{type: :string, nullable: true}
      },
      required: [:task_id, :labor_major]
    })
  end

  defmodule ExtraTaskLaborResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileExtraTaskLaborResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MithrilWeb.Schemas.MobileCalls.ExtraTaskLaborQuote}
      },
      required: [:data]
    })
  end

  defmodule ManageExtraTasksRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileManageExtraTasksRequest",
      type: :object,
      properties: %{
        action: %Schema{type: :string, nullable: true},
        new_hours: %Schema{type: :number, nullable: true},
        task_id: %Schema{type: :string, nullable: true}
      }
    })
  end

  defmodule ExtraTaskCatalogItem do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileExtraTaskCatalogItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        label: %Schema{type: :string},
        hours: %Schema{type: :number},
        icon_key: %Schema{type: :string, nullable: true},
        task_id: %Schema{type: :string, nullable: true},
        name: %Schema{type: :string, nullable: true},
        title: %Schema{type: :string, nullable: true},
        pricing_mode: %Schema{type: :string, nullable: true},
        flat_price_minor: %Schema{type: :integer, nullable: true}
      },
      required: [:id, :label, :hours]
    })
  end

  defmodule ExtraTaskCatalogResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileExtraTaskCatalogResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MithrilWeb.Schemas.MobileCalls.ExtraTaskCatalogItem}
      },
      required: [:data]
    })
  end

  defmodule AiMatchSettings do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileAiMatchSettings",
      type: :object,
      properties: %{
        enabled: %Schema{type: :boolean},
        model: %Schema{type: :string},
        fallback_model: %Schema{type: :string},
        allowed_models: %Schema{type: :array, items: %Schema{type: :string}},
        temperature: %Schema{type: :number},
        max_tokens: %Schema{type: :integer},
        response_format: %Schema{type: :string}
      },
      required: [
        :enabled,
        :model,
        :fallback_model,
        :allowed_models,
        :temperature,
        :max_tokens,
        :response_format
      ]
    })
  end

  defmodule AiMatchSettingsResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MobileAiMatchSettingsResponse",
      type: :object,
      properties: %{
        data: MithrilWeb.Schemas.MobileCalls.AiMatchSettings
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

  def operation({:user_rpc, "get_location_current_time"}) do
    post("mobile.getLocationTime", "Local time and same-day cutoff for a timezone",
      request: LocationTimeRequest,
      response: LocationTimeResponse
    )
  end

  def operation({:guest_rpc, "get_location_current_time"}) do
    post(
      "mobile.getLocationTimeGuest",
      "Local time and same-day cutoff for a timezone, without a signed-in user",
      request: LocationTimeRequest,
      response: LocationTimeResponse
    )
  end

  def operation({:user_rpc, "get_available_timeslots"}) do
    post("mobile.getAvailableTimeslots", "Bookable times for a date",
      request: AvailableTimeslotsRequest,
      response: AvailableTimeslotsResponse
    )
  end

  def operation({:guest_rpc, "get_available_timeslots"}) do
    post(
      "mobile.getAvailableTimeslotsGuest",
      "Bookable times for a date, without a signed-in user",
      request: AvailableTimeslotsRequest,
      response: AvailableTimeslotsResponse
    )
  end

  def operation({:user_rpc, "validate_booking_timeslot"}) do
    post("mobile.validateBookingTimeslot", "Whether one booking start time is allowed",
      request: ValidateTimeslotRequest,
      response: ValidateTimeslotResponse
    )
  end

  def operation({:guest_rpc, "validate_booking_timeslot"}) do
    post(
      "mobile.validateBookingTimeslotGuest",
      "Whether one booking start time is allowed, without a signed-in user",
      request: ValidateTimeslotRequest,
      response: ValidateTimeslotResponse
    )
  end

  def operation({:user_action, "timezone"}) do
    post("mobile.getTimezone", "IANA timezone for coordinates",
      request: TimezoneRequest,
      response: TimezoneResponse
    )
  end

  def operation({:guest_action, "timezone"}) do
    post("mobile.getTimezoneGuest", "IANA timezone for coordinates, without a signed-in user",
      request: TimezoneRequest,
      response: TimezoneResponse
    )
  end

  def operation({:user_rpc, "compute_extra_task_labor_quotes"}) do
    post("mobile.getExtraTaskLaborQuotes", "Labor price for selected extra tasks",
      request: ExtraTaskLaborRequest,
      response: ExtraTaskLaborResponse
    )
  end

  def operation({:guest_rpc, "compute_extra_task_labor_quotes"}) do
    post(
      "mobile.getExtraTaskLaborQuotesGuest",
      "Labor price for selected extra tasks, without a signed-in user",
      request: ExtraTaskLaborRequest,
      response: ExtraTaskLaborResponse
    )
  end

  def operation({:user_rpc, "manage_extra_tasks"}) do
    post("mobile.manageExtraTasks", "Read or update the extra-task catalog",
      request: ManageExtraTasksRequest,
      response: ExtraTaskCatalogResponse
    )
  end

  def operation({:guest_rpc, "manage_extra_tasks"}) do
    post(
      "mobile.manageExtraTasksGuest",
      "Read the extra-task catalog without a signed-in user",
      request: ManageExtraTasksRequest,
      response: ExtraTaskCatalogResponse
    )
  end

  def operation({:user_rpc, "get_ai_match_settings"}) do
    post("mobile.getAiMatchSettings", "AI match settings for the signed-in user",
      response: AiMatchSettingsResponse
    )
  end

  def operation({:guest_rpc, "get_ai_match_settings"}) do
    post(
      "mobile.getAiMatchSettingsGuest",
      "AI match settings without a signed-in user",
      response: AiMatchSettingsResponse
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
