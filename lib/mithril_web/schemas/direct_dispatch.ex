defmodule MithrilWeb.Schemas.DirectDispatch do
  @moduledoc "OpenAPI schemas for Direct concierge and dispatch operations."

  defmodule UrgentHelpRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectUrgentHelpRequest",
      type: :object,
      properties: %{
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
        },
        priority: %Schema{type: :string, enum: ~w(urgent same_day standard), default: "urgent"},
        neededBy: %Schema{type: :string, format: :"date-time"},
        durationHours: %Schema{type: :number, minimum: 0.5, maximum: 24},
        householdAddress: %Schema{type: :string, minLength: 3, maxLength: 500},
        requirements: %Schema{type: :object, additionalProperties: true, default: %{}},
        notes: %Schema{type: :string, maxLength: 4000, nullable: true}
      },
      required: [:role, :neededBy, :durationHours, :householdAddress]
    })
  end

  defmodule ReplacementRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectReplacementRequest",
      type: :object,
      properties: %{
        priority: %Schema{type: :string, enum: ~w(urgent same_day standard), default: "same_day"},
        requirements: %Schema{type: :object, additionalProperties: true, default: %{}},
        notes: %Schema{type: :string, maxLength: 4000, nullable: true}
      }
    })
  end

  defmodule CreateServiceRequestResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCreateServiceRequestResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ~w(submitted triaging matching assigned resolved cancelled)
        },
        kind: %Schema{type: :string, enum: ~w(urgent_help replacement)},
        relatedBookingId: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:id, :status, :kind]
    })
  end

  defmodule ServiceRequestItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectServiceRequestItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ~w(urgent_help replacement)},
        status: %Schema{
          type: :string,
          enum: ~w(submitted triaging matching assigned resolved cancelled)
        },
        priority: %Schema{type: :string, enum: ~w(urgent same_day standard)},
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener),
          nullable: true
        },
        requestedStartAt: %Schema{type: :string, format: :"date-time", nullable: true},
        durationHours: %Schema{type: :number, nullable: true},
        householdAddress: %Schema{type: :string},
        relatedBookingId: %Schema{type: :string, format: :uuid, nullable: true},
        requirements: %Schema{type: :object, additionalProperties: true},
        notes: %Schema{type: :string, nullable: true},
        assignedWorkerUserId: %Schema{type: :string, format: :uuid, nullable: true},
        assignedWorkerName: %Schema{type: :string, nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time"},
        updatedAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :kind,
        :status,
        :priority,
        :role,
        :requestedStartAt,
        :durationHours,
        :householdAddress,
        :relatedBookingId,
        :requirements,
        :notes,
        :assignedWorkerUserId,
        :assignedWorkerName,
        :createdAt,
        :updatedAt
      ]
    })
  end

  defmodule ServiceRequestListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectDispatch.ServiceRequestItem
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectServiceRequestListResponse",
      type: :object,
      properties: %{
        requests: %Schema{type: :array, items: ServiceRequestItem}
      },
      required: [:requests]
    })
  end

  defmodule AdminCustomer do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomer",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true}
      },
      required: [:userId, :name, :email, :phone]
    })
  end

  defmodule AdminCustomerListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectDispatch.AdminCustomer
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerListResponse",
      type: :object,
      properties: %{
        customers: %Schema{type: :array, items: AdminCustomer}
      },
      required: [:customers]
    })
  end

  defmodule AdminAssistedBookingRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAssistedBookingRequest",
      type: :object,
      properties: %{
        customerUserId: %Schema{type: :string, format: :uuid},
        serviceId: %Schema{type: :integer, minimum: 1},
        cleanerId: %Schema{type: :string, format: :uuid},
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string, pattern: "^([01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d)?$"},
        durationHours: %Schema{type: :number, minimum: 0.5},
        address: %Schema{type: :string, minLength: 3, maxLength: 500},
        specialInstructions: %Schema{type: :string, maxLength: 4000, nullable: true},
        timezone: %Schema{type: :string, default: "Africa/Accra"},
        source: %Schema{type: :string, enum: ~w(admin phone whatsapp), default: "admin"},
        consentConfirmed: %Schema{type: :boolean},
        adminNote: %Schema{type: :string, maxLength: 2000, nullable: true}
      },
      required: [
        :customerUserId,
        :serviceId,
        :cleanerId,
        :scheduledDate,
        :scheduledTime,
        :durationHours,
        :address,
        :consentConfirmed
      ]
    })
  end

  defmodule AdminAssistedBookingResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAssistedBookingResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        paymentStatus: %Schema{type: :string},
        amountMinor: %Schema{type: :integer, minimum: 0},
        currency: %Schema{type: :string},
        customerUserId: %Schema{type: :string, format: :uuid},
        source: %Schema{type: :string, enum: ~w(admin phone whatsapp)},
        createdByAdmin: %Schema{type: :boolean}
      },
      required: [
        :id,
        :status,
        :paymentStatus,
        :amountMinor,
        :currency,
        :customerUserId,
        :source,
        :createdByAdmin
      ]
    })
  end

  defmodule AdminServiceRequestItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceRequestItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        customerUserId: %Schema{type: :string, format: :uuid},
        customerName: %Schema{type: :string},
        customerPhone: %Schema{type: :string, nullable: true},
        kind: %Schema{type: :string, enum: ~w(urgent_help replacement)},
        status: %Schema{
          type: :string,
          enum: ~w(submitted triaging matching assigned resolved cancelled)
        },
        priority: %Schema{type: :string, enum: ~w(urgent same_day standard)},
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener),
          nullable: true
        },
        requestedStartAt: %Schema{type: :string, format: :"date-time", nullable: true},
        durationHours: %Schema{type: :number, nullable: true},
        householdAddress: %Schema{type: :string},
        relatedBookingId: %Schema{type: :string, format: :uuid, nullable: true},
        requirements: %Schema{type: :object, additionalProperties: true},
        notes: %Schema{type: :string, nullable: true},
        adminNote: %Schema{type: :string, nullable: true},
        assignedWorkerUserId: %Schema{type: :string, format: :uuid, nullable: true},
        assignedWorkerName: %Schema{type: :string, nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time"},
        updatedAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :customerUserId,
        :customerName,
        :customerPhone,
        :kind,
        :status,
        :priority,
        :role,
        :requestedStartAt,
        :durationHours,
        :householdAddress,
        :relatedBookingId,
        :requirements,
        :notes,
        :adminNote,
        :assignedWorkerUserId,
        :assignedWorkerName,
        :createdAt,
        :updatedAt
      ]
    })
  end

  defmodule AdminServiceRequestListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectDispatch.AdminServiceRequestItem
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceRequestListResponse",
      type: :object,
      properties: %{
        requests: %Schema{type: :array, items: AdminServiceRequestItem}
      },
      required: [:requests]
    })
  end

  defmodule AdminAssignServiceRequestRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAssignServiceRequestRequest",
      type: :object,
      properties: %{
        workerUserId: %Schema{type: :string, format: :uuid},
        adminNote: %Schema{type: :string, maxLength: 2000, nullable: true}
      },
      required: [:workerUserId]
    })
  end

  defmodule AdminUpdateServiceRequestRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminUpdateServiceRequestRequest",
      type: :object,
      properties: %{
        status: %Schema{
          type: :string,
          enum: ~w(submitted triaging matching assigned resolved cancelled)
        },
        adminNote: %Schema{type: :string, maxLength: 2000, nullable: true}
      },
      required: [:status]
    })
  end

  defmodule AdminServiceRequestMutationResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminServiceRequestMutationResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ~w(submitted triaging matching assigned resolved cancelled)
        },
        assignedWorkerUserId: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:id, :status]
    })
  end
end
