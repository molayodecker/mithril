defmodule MithrilWeb.Schemas.DirectOperations do
  @moduledoc "OpenAPI schemas for customer/admin operations used by Instaclean agents."

  defmodule CancelBookingRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCancelBookingRequest",
      type: :object,
      properties: %{
        reason: %Schema{type: :string, nullable: true, maxLength: 500}
      }
    })
  end

  defmodule CancellationPolicyResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCancellationPolicyResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        canCancel: %Schema{type: :boolean},
        refundTier: %Schema{type: :string},
        refundPercent: %Schema{type: :integer},
        refundAmountMinor: %Schema{type: :integer},
        alreadyRefundedAmountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string},
        recurring: %Schema{type: :boolean}
      },
      required: [
        :id,
        :status,
        :paymentStatus,
        :canCancel,
        :refundTier,
        :refundPercent,
        :refundAmountMinor,
        :alreadyRefundedAmountMinor,
        :currency,
        :scheduledDate,
        :scheduledTime,
        :recurring
      ]
    })
  end

  defmodule RefundRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectRefundRequest",
      type: :object,
      properties: %{
        reason: %Schema{type: :string, minLength: 3, maxLength: 2000}
      },
      required: [:reason]
    })
  end

  defmodule RefundRequestResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectRefundRequestResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        existing: %Schema{type: :boolean}
      },
      required: [:id, :status, :existing]
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
        timezone: %Schema{type: :string, nullable: true}
      },
      required: [:scheduledDate, :scheduledTime]
    })
  end

  defmodule RescheduleBookingResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectRescheduleBookingResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        oldScheduledDate: %Schema{type: :string},
        oldScheduledTime: %Schema{type: :string},
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string},
        timezone: %Schema{type: :string}
      },
      required: [
        :id,
        :status,
        :oldScheduledDate,
        :oldScheduledTime,
        :scheduledDate,
        :scheduledTime,
        :timezone
      ]
    })
  end

  defmodule CleanerListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerListResponse",
      type: :object,
      properties: %{
        cleaners: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}}
      },
      required: [:cleaners]
    })
  end

  defmodule CleanerApplicationListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApplicationListResponse",
      type: :object,
      properties: %{
        applications: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true}
        }
      },
      required: [:applications]
    })
  end

  defmodule CleanerApprovalResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApprovalResponse",
      type: :object,
      additionalProperties: true
    })
  end

  defmodule PaymentDiagnosticsResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPaymentDiagnosticsResponse",
      type: :object,
      properties: %{
        bookingId: %Schema{type: :string, format: :uuid},
        bookingStatus: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        bookingReference: %Schema{type: :string, nullable: true},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        attempts: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        provider: %Schema{type: :object, additionalProperties: true},
        likelyReason: %Schema{type: :string, nullable: true}
      },
      required: [
        :bookingId,
        :bookingStatus,
        :paymentStatus,
        :amountMinor,
        :currency,
        :attempts,
        :provider
      ]
    })
  end
end
