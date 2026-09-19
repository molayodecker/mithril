defmodule MithrilWeb.Schemas.DirectAdminBooking do
  @moduledoc "OpenAPI schemas for the Direct admin bookings desk."

  defmodule PayoutMethod do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBookingPayoutMethod",
      type: :object,
      properties: %{
        bankName: %Schema{type: :string, nullable: true},
        maskedAccount: %Schema{type: :string},
        accountName: %Schema{type: :string, nullable: true},
        accountNumber: %Schema{type: :string}
      },
      required: [:maskedAccount, :accountNumber]
    })
  end

  defmodule AdminBooking do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminBooking.PayoutMethod
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBooking",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        serviceId: %Schema{type: :integer, nullable: true},
        serviceName: %Schema{type: :string},
        scheduledDate: %Schema{type: :string, format: :date, nullable: true},
        scheduledTime: %Schema{type: :string, nullable: true},
        durationHours: %Schema{type: :number, nullable: true},
        timezone: %Schema{type: :string, nullable: true},
        address: %Schema{type: :string, nullable: true},
        specialInstructions: %Schema{type: :string, nullable: true},
        amountMinor: %Schema{type: :integer},
        cleanerEarningsMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        customerId: %Schema{type: :string, format: :uuid},
        customerName: %Schema{type: :string},
        customerEmail: %Schema{type: :string, nullable: true},
        customerPhone: %Schema{type: :string, nullable: true},
        cleanerId: %Schema{type: :string, format: :uuid, nullable: true},
        cleanerName: %Schema{type: :string, nullable: true},
        cleanerPhone: %Schema{type: :string, nullable: true},
        cleanerEmail: %Schema{type: :string, nullable: true},
        walletBalanceMinor: %Schema{type: :integer, nullable: true},
        walletCurrency: %Schema{type: :string, nullable: true},
        payoutMethod: %Schema{allOf: [PayoutMethod], nullable: true},
        assignmentPhase: %Schema{type: :string, nullable: true},
        assignmentHoldUntil: %Schema{type: :string, format: :"date-time", nullable: true},
        cleanerAcceptedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        directAssignedCleanerId: %Schema{type: :string, format: :uuid, nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        canReassignCleaner: %Schema{type: :boolean},
        canCancel: %Schema{type: :boolean},
        canChangeStatus: %Schema{type: :boolean},
        canResetHold: %Schema{type: :boolean},
        canRecordCashPayout: %Schema{type: :boolean}
      },
      required: [
        :id,
        :status,
        :paymentStatus,
        :serviceName,
        :amountMinor,
        :cleanerEarningsMinor,
        :currency,
        :customerId,
        :customerName,
        :canReassignCleaner,
        :canCancel,
        :canChangeStatus,
        :canResetHold,
        :canRecordCashPayout
      ]
    })
  end

  defmodule AdminBookingListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminBooking.AdminBooking
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBookingListResponse",
      type: :object,
      properties: %{bookings: %Schema{type: :array, items: AdminBooking}},
      required: [:bookings]
    })
  end

  defmodule AssignCleanerRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAssignBookingCleanerRequest",
      type: :object,
      properties: %{
        cleanerId: %Schema{type: :string, format: :uuid}
      },
      required: [:cleanerId]
    })
  end

  defmodule UpdateStatusRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminUpdateBookingStatusRequest",
      type: :object,
      properties: %{
        status: %Schema{
          type: :string,
          enum: ~w(pending confirmed scheduled en_route arrived in_progress completed)
        }
      },
      required: [:status]
    })
  end

  defmodule CashPayoutRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCashPayoutRequest",
      type: :object,
      properties: %{
        amountMinor: %Schema{type: :integer, minimum: 1},
        notes: %Schema{type: :string, maxLength: 500, nullable: true}
      },
      required: [:amountMinor]
    })
  end

  defmodule CashPayoutResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCashPayoutResponse",
      type: :object,
      properties: %{
        amountMinor: %Schema{type: :integer},
        newBalanceMinor: %Schema{type: :integer, nullable: true}
      },
      required: [:amountMinor]
    })
  end

  defmodule NotifyResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBookingNotifyResponse",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        sent: %Schema{type: :boolean}
      },
      required: [:ok, :sent]
    })
  end

  defmodule ResetHoldRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminResetExclusiveHoldRequest",
      type: :object,
      properties: %{
        cleanerId: %Schema{type: :string, format: :uuid, nullable: true}
      }
    })
  end

  defmodule MutationOkResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBookingMutationResponse",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean}
      },
      required: [:ok]
    })
  end
end
