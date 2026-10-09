defmodule MithrilWeb.Schemas.DirectBooking do
  @moduledoc "OpenAPI schemas for the Instaclean Direct on-demand booking flow."

  defmodule BookingService do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingService",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string},
        priceGhs: %Schema{type: :number},
        minimumDurationHours: %Schema{type: :number},
        maximumDurationHours: %Schema{type: :number},
        durationIncrementHours: %Schema{type: :number},
        specialtySlug: %Schema{type: :string, nullable: true},
        category: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        features: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
        weight: %Schema{type: :integer, minimum: 0}
      },
      required: [
        :id,
        :name,
        :category,
        :priceGhs,
        :minimumDurationHours,
        :maximumDurationHours,
        :durationIncrementHours,
        :specialtySlug
      ]
    })
  end

  defmodule BookingServicesResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectBooking.BookingService
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingServicesResponse",
      type: :object,
      properties: %{services: %Schema{type: :array, items: BookingService}},
      required: [:services]
    })
  end

  defmodule BookingCategory do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingCategory",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string},
        icon: %Schema{type: :string, nullable: true},
        slug: %Schema{type: :string, nullable: true},
        weight: %Schema{type: :integer, minimum: 0},
        description: %Schema{type: :string, nullable: true},
        imageUrl: %Schema{type: :string, nullable: true},
        iconScale: %Schema{type: :number, nullable: true}
      },
      required: [:id, :name]
    })
  end

  defmodule BookingCategoriesResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectBooking.BookingCategory
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingCategoriesResponse",
      type: :object,
      properties: %{categories: %Schema{type: :array, items: BookingCategory}},
      required: [:categories]
    })
  end

  defmodule CleanerListItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingCleaner",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        avatarUrl: %Schema{type: :string, nullable: true},
        rating: %Schema{type: :number, nullable: true},
        completedJobs: %Schema{type: :integer, nullable: true},
        hourlyRateGhs: %Schema{type: :number}
      },
      required: [:userId, :name, :avatarUrl, :rating, :completedJobs, :hourlyRateGhs]
    })
  end

  defmodule CleanerListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectBooking.CleanerListItem
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingCleanerListResponse",
      type: :object,
      properties: %{cleaners: %Schema{type: :array, items: CleanerListItem}},
      required: [:cleaners]
    })
  end

  defmodule BookingPricingRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingPricingRequest",
      type: :object,
      properties: %{
        serviceId: %Schema{type: :integer, minimum: 1},
        cleanerId: %Schema{type: :string, format: :uuid},
        scheduledDate: %Schema{type: :string, format: :date},
        durationHours: %Schema{type: :number, minimum: 0},
        timezone: %Schema{type: :string, default: "Africa/Accra"},
        recurrenceInterval: %Schema{
          type: :string,
          enum: ~w(daily weekly monthly quarterly annually),
          nullable: true,
          description: "Repeat schedule. Omit for a one-time visit."
        }
      },
      required: [:serviceId, :cleanerId, :scheduledDate, :durationHours]
    })
  end

  defmodule BookingPriceResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingPriceResponse",
      type: :object,
      properties: %{
        currency: %Schema{type: :string},
        pricingVersion: %Schema{type: :string},
        durationHours: %Schema{type: :number},
        workRateGhsPerHour: %Schema{type: :number},
        subtotalLaborMajor: %Schema{type: :number},
        platformFeeMajor: %Schema{type: :number},
        bookingCoverMajor: %Schema{type: :number},
        coreAmountMinor: %Schema{type: :integer},
        sameDaySurchargeMinor: %Schema{type: :integer},
        weekendSurchargeMinor: %Schema{type: :integer},
        recurringDiscountMinor: %Schema{type: :integer},
        finalAmountMinor: %Schema{type: :integer},
        isSameDay: %Schema{type: :boolean},
        isWeekend: %Schema{type: :boolean},
        suppliesOption: %Schema{type: :string},
        suppliesAllowanceMinor: %Schema{type: :integer},
        cleanerEarningsMinor: %Schema{type: :integer, nullable: true},
        recurringAmountMinor: %Schema{type: :integer, nullable: true},
        firstChargeAmountMinor: %Schema{type: :integer, nullable: true},
        discountRateBps: %Schema{type: :integer, nullable: true}
      },
      required: [
        :currency,
        :pricingVersion,
        :durationHours,
        :workRateGhsPerHour,
        :subtotalLaborMajor,
        :platformFeeMajor,
        :bookingCoverMajor,
        :coreAmountMinor,
        :sameDaySurchargeMinor,
        :weekendSurchargeMinor,
        :recurringDiscountMinor,
        :finalAmountMinor,
        :isSameDay,
        :isWeekend,
        :suppliesOption,
        :suppliesAllowanceMinor,
        :cleanerEarningsMinor
      ]
    })
  end

  defmodule CreateBookingRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCreateBookingRequest",
      type: :object,
      properties: %{
        serviceId: %Schema{type: :integer, minimum: 1},
        cleanerId: %Schema{type: :string, format: :uuid},
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string, example: "09:00"},
        durationHours: %Schema{type: :number, minimum: 0},
        address: %Schema{type: :string, minLength: 3, maxLength: 500},
        specialInstructions: %Schema{type: :string, nullable: true, maxLength: 4000},
        timezone: %Schema{type: :string, default: "Africa/Accra"},
        idempotencyKey: %Schema{
          type: :string,
          minLength: 8,
          maxLength: 128,
          description: "Per-booking intent key reused across retries"
        },
        recurrenceInterval: %Schema{
          type: :string,
          enum: ~w(daily weekly monthly quarterly annually),
          nullable: true,
          description:
            "Paystack-native repeat schedule. Omit for a one-time visit. Creates a pending subscription for the first visit."
        },
        bookingForSelf: %Schema{type: :boolean, default: true},
        siteContactName: %Schema{type: :string, nullable: true, maxLength: 120},
        siteContactPhone: %Schema{type: :string, nullable: true, maxLength: 24},
        siteContactRelationship: %Schema{type: :string, nullable: true, maxLength: 80},
        propertyType: %Schema{
          type: :string,
          nullable: true,
          enum: ~w(residential vacant_home office commercial airbnb_turnover post_construction)
        },
        occupantPresent: %Schema{type: :boolean, nullable: true},
        requiresKeyOrAccessCode: %Schema{type: :boolean, default: false},
        accessInstructions: %Schema{type: :string, nullable: true, maxLength: 2000},
        customerContactPhone: %Schema{type: :string, nullable: true, maxLength: 24},
        turnoverGuestCheckoutAt: %Schema{type: :string, format: :"date-time", nullable: true},
        turnoverNextCheckInAt: %Schema{type: :string, format: :"date-time", nullable: true},
        turnoverLinenHandling: %Schema{
          type: :string,
          nullable: true,
          enum: ~w(replace_no_wash wash_hang_dry wash_dry_repack_onsite no_bedding_replace)
        },
        turnoverRestockingNotes: %Schema{type: :string, nullable: true, maxLength: 2000},
        turnoverSource: %Schema{type: :string, nullable: true, enum: ~w(manual airbnb_ical)},
        turnoverOpportunityId: %Schema{type: :string, format: :uuid, nullable: true},
        propertyId: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [
        :serviceId,
        :cleanerId,
        :scheduledDate,
        :scheduledTime,
        :durationHours,
        :address
      ]
    })
  end

  defmodule ReplaceUnpaidBookingRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectReplaceUnpaidBookingRequest",
      type: :object,
      properties: %{
        serviceId: %Schema{type: :integer, minimum: 1},
        cleanerId: %Schema{type: :string, format: :uuid},
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string, example: "09:00"},
        durationHours: %Schema{type: :number, minimum: 0},
        address: %Schema{type: :string, minLength: 3, maxLength: 500},
        specialInstructions: %Schema{type: :string, nullable: true, maxLength: 4000},
        timezone: %Schema{type: :string, default: "Africa/Accra"},
        idempotencyKey: %Schema{
          type: :string,
          minLength: 8,
          maxLength: 128,
          description: "Required replacement intent key reused across retries"
        },
        bookingForSelf: %Schema{type: :boolean, default: true},
        siteContactName: %Schema{type: :string, nullable: true, maxLength: 120},
        siteContactPhone: %Schema{type: :string, nullable: true, maxLength: 24},
        siteContactRelationship: %Schema{type: :string, nullable: true, maxLength: 80},
        propertyType: %Schema{
          type: :string,
          nullable: true,
          enum: ~w(residential vacant_home office commercial airbnb_turnover post_construction)
        },
        occupantPresent: %Schema{type: :boolean, nullable: true},
        requiresKeyOrAccessCode: %Schema{type: :boolean, default: false},
        accessInstructions: %Schema{type: :string, nullable: true, maxLength: 2000},
        customerContactPhone: %Schema{type: :string, nullable: true, maxLength: 24},
        turnoverGuestCheckoutAt: %Schema{type: :string, format: :"date-time", nullable: true},
        turnoverNextCheckInAt: %Schema{type: :string, format: :"date-time", nullable: true},
        turnoverLinenHandling: %Schema{
          type: :string,
          nullable: true,
          enum: ~w(replace_no_wash wash_hang_dry wash_dry_repack_onsite no_bedding_replace)
        },
        turnoverRestockingNotes: %Schema{type: :string, nullable: true, maxLength: 2000},
        turnoverSource: %Schema{type: :string, nullable: true, enum: ~w(manual airbnb_ical)},
        turnoverOpportunityId: %Schema{type: :string, format: :uuid, nullable: true},
        propertyId: %Schema{type: :string, format: :uuid, nullable: true},
        recurrenceInterval: %Schema{
          type: :string,
          enum: ~w(daily weekly monthly quarterly annually),
          nullable: true
        }
      },
      required: [
        :serviceId,
        :cleanerId,
        :scheduledDate,
        :scheduledTime,
        :durationHours,
        :address,
        :idempotencyKey
      ]
    })
  end

  defmodule RescheduleBookingRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectRescheduleBookingRequest",
      type: :object,
      properties: %{
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string, example: "09:00"},
        durationHours: %Schema{type: :number, nullable: true, minimum: 0},
        timezone: %Schema{type: :string, default: "Africa/Accra"}
      },
      required: [:scheduledDate, :scheduledTime, :timezone]
    })
  end

  defmodule CreateBookingResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCreateBookingResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        subscriptionId: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Pending subscription created for a recurring visit"
        }
      },
      required: [:id, :status, :paymentStatus, :amountMinor, :currency]
    })
  end

  defmodule BookingDetailResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingDetailResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        serviceId: %Schema{type: :integer},
        serviceName: %Schema{type: :string},
        cleanerId: %Schema{type: :string, format: :uuid},
        cleanerName: %Schema{type: :string},
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string},
        durationHours: %Schema{type: :number},
        address: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string}
      },
      required: [
        :id,
        :status,
        :paymentStatus,
        :serviceId,
        :serviceName,
        :cleanerId,
        :cleanerName,
        :scheduledDate,
        :scheduledTime,
        :durationHours,
        :address,
        :amountMinor,
        :currency
      ]
    })
  end

  defmodule BookingListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectBooking.BookingDetailResponse
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectBookingListResponse",
      type: :object,
      properties: %{bookings: %Schema{type: :array, items: BookingDetailResponse}},
      required: [:bookings]
    })
  end

  defmodule CancelBookingRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCancelBookingRequest",
      type: :object,
      properties: %{
        cancellationReason: %Schema{
          type: :string,
          maxLength: 500,
          nullable: true,
          description: "Optional customer note stored on the cancelled booking"
        }
      }
    })
  end

  defmodule CancelBookingResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCancelBookingResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        currency: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        tier: %Schema{
          type: :string,
          enum: ["full_refund", "partial_refund", "no_refund"]
        },
        refundPercent: %Schema{type: :integer, enum: [0, 50, 100]},
        refundAmountMinor: %Schema{type: :integer},
        refundStatus: %Schema{
          type: :string,
          enum: ["skipped", "pending", "processed", "failed", "manual_review"]
        },
        successMessage: %Schema{type: :string}
      },
      required: [
        :id,
        :status,
        :paymentStatus,
        :currency,
        :amountMinor,
        :tier,
        :refundPercent,
        :refundAmountMinor,
        :refundStatus,
        :successMessage
      ]
    })
  end

  defmodule InitializePaymentRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectInitializePaymentRequest",
      type: :object,
      properties: %{
        callbackUrl: %Schema{
          type: :string,
          format: :uri,
          description: "Direct booking confirmation URL Paystack should return to"
        }
      },
      required: [:callbackUrl]
    })
  end

  defmodule PaymentCheckoutResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPaymentCheckoutResponse",
      type: :object,
      properties: %{
        authorizationUrl: %Schema{type: :string, format: :uri},
        accessCode: %Schema{type: :string, nullable: true},
        reference: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string}
      },
      required: [
        :authorizationUrl,
        :accessCode,
        :reference,
        :paymentStatus,
        :amountMinor,
        :currency
      ]
    })
  end

  defmodule VerifyPaymentRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectVerifyPaymentRequest",
      type: :object,
      properties: %{
        reference: %Schema{type: :string, nullable: true}
      }
    })
  end

  defmodule PaymentVerifyResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPaymentVerifyResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        reference: %Schema{type: :string, nullable: true}
      },
      required: [:id, :status, :paymentStatus, :amountMinor, :currency]
    })
  end
end
