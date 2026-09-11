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
        specialtySlug: %Schema{type: :string, nullable: true}
      },
      required: [
        :id,
        :name,
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
        timezone: %Schema{type: :string, default: "Africa/Accra"}
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
        cleanerEarningsMinor: %Schema{type: :integer, nullable: true}
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
        timezone: %Schema{type: :string, default: "Africa/Accra"}
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
        currency: %Schema{type: :string}
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
