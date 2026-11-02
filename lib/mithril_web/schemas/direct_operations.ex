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

  defmodule AdminCleanerRosterItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerRosterItem",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string},
        verified: %Schema{type: :boolean},
        rating: %Schema{type: :number, nullable: true},
        completedJobs: %Schema{type: :integer, nullable: true},
        hourlyRateGhs: %Schema{type: :number, nullable: true},
        specialties: %Schema{type: :array, items: %Schema{type: :string}},
        applicationId: %Schema{type: :string, format: :uuid, nullable: true},
        applicationStatus: %Schema{type: :string, nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:userId, :name, :status, :verified, :specialties]
    })
  end

  defmodule CleanerListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectOperations.AdminCleanerRosterItem
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerListResponse",
      type: :object,
      properties: %{
        cleaners: %Schema{type: :array, items: AdminCleanerRosterItem}
      },
      required: [:cleaners]
    })
  end

  defmodule CleanerApprovalResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApprovalResponse",
      type: :object,
      description: "JSON returned by public.approve_cleaner_application/1",
      properties: %{
        success: %Schema{type: :boolean, nullable: true},
        applicationId: %Schema{type: :string, format: :uuid, nullable: true},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        cleanerId: %Schema{type: :string, format: :uuid, nullable: true},
        status: %Schema{type: :string, nullable: true},
        message: %Schema{type: :string, nullable: true}
      }
    })
  end

  defmodule PaymentAttemptDiagnostics do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPaymentAttemptDiagnostics",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        reference: %Schema{type: :string, nullable: true},
        amountMinor: %Schema{type: :integer, nullable: true},
        currency: %Schema{type: :string, nullable: true},
        failureReason: %Schema{type: :string, nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        readyAt: %Schema{type: :string, format: :"date-time", nullable: true},
        paidAt: %Schema{type: :string, format: :"date-time", nullable: true},
        failedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :status]
    })
  end

  defmodule PaymentProviderDiagnostics do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPaymentProviderDiagnostics",
      type: :object,
      properties: %{
        status: %Schema{type: :string},
        reference: %Schema{type: :string, nullable: true},
        reason: %Schema{type: :string, nullable: true},
        amountMinor: %Schema{type: :integer, nullable: true},
        currency: %Schema{type: :string, nullable: true},
        httpStatus: %Schema{type: :integer, nullable: true}
      },
      required: [:status]
    })
  end

  defmodule PaymentDiagnosticsResponse do
    require OpenApiSpex

    alias MithrilWeb.Schemas.DirectOperations.{
      PaymentAttemptDiagnostics,
      PaymentProviderDiagnostics
    }

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
        attempts: %Schema{type: :array, items: PaymentAttemptDiagnostics},
        provider: PaymentProviderDiagnostics,
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
