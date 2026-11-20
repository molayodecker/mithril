defmodule MithrilWeb.Schemas.DirectDispatch do
  @moduledoc "OpenAPI schemas for Direct concierge and dispatch operations."

  defmodule UrgentHelpRequest do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectRequirements
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
        requirements: DirectRequirements,
        notes: %Schema{type: :string, maxLength: 4000, nullable: true},
        idempotencyKey: %Schema{
          type: :string,
          minLength: 8,
          maxLength: 128,
          nullable: true,
          description: "Stable per-intent key so retries return the same urgent-help request."
        }
      },
      required: [:role, :neededBy, :durationHours, :householdAddress]
    })
  end

  defmodule ReplacementRequest do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectRequirements
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectReplacementRequest",
      type: :object,
      properties: %{
        priority: %Schema{type: :string, enum: ~w(urgent same_day standard), default: "same_day"},
        neededBy: %Schema{type: :string, format: :"date-time", nullable: true},
        requirements: DirectRequirements,
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
    alias MithrilWeb.Schemas.DirectRequirements
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
        requirements: DirectRequirements,
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
        scheduledTime: %Schema{
          type: :string,
          pattern: "^([01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d)?$"
        },
        bedrooms: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 10,
          nullable: true,
          description:
            "When set with bathrooms, the database computes durationHours and homeSize."
        },
        bathrooms: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 10,
          nullable: true,
          description: "When set with bedrooms, the database computes durationHours and homeSize."
        },
        durationHours: %Schema{
          type: :number,
          minimum: 0.5,
          nullable: true,
          description:
            "Used only when bedrooms and bathrooms are omitted. Room counts replace this value."
        },
        homeSize: %Schema{
          type: :string,
          nullable: true,
          maxLength: 200,
          description:
            "Legacy room summary. Replaced by the database when bedrooms and bathrooms are sent."
        },
        address: %Schema{type: :string, minLength: 3, maxLength: 500},
        specialInstructions: %Schema{type: :string, maxLength: 4000, nullable: true},
        timezone: %Schema{type: :string, default: "Africa/Accra"},
        scheduleKind: %Schema{
          type: :string,
          enum: ~w(once recurring custom_days),
          default: "once"
        },
        recurrenceInterval: %Schema{
          type: :string,
          enum: ~w(daily weekly bi_weekly monthly quarterly annually),
          nullable: true
        },
        occurrenceCount: %Schema{type: :integer, minimum: 2, maximum: 12, nullable: true},
        customDates: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :date},
          maxItems: 14,
          nullable: true
        },
        source: %Schema{type: :string, enum: ~w(admin phone whatsapp), default: "admin"},
        consentConfirmed: %Schema{type: :boolean},
        idempotencyKey: %Schema{
          type: :string,
          minLength: 8,
          maxLength: 128,
          nullable: true,
          description:
            "Stable per-intent key. Retries with the same key return the same booking or booking series."
        },
        sendNotifications: %Schema{
          type: :boolean,
          default: true,
          description:
            "When true, notify the customer and assigned professional after create. Uncheck when they already confirmed on the same call or WhatsApp thread."
        },
        adminNote: %Schema{type: :string, maxLength: 2000, nullable: true},
        extraTaskIds: %Schema{
          type: :array,
          items: %Schema{type: :string, minLength: 1, maxLength: 64},
          maxItems: 32,
          nullable: true,
          description:
            "Cleaning extra tasks. Catalog hours are added to the room visit before pricing."
        },
        promotionSlug: %Schema{
          type: :string,
          nullable: true,
          maxLength: 80,
          description:
            "Optional active promotion. Checked against this customer and applied to the first visit."
        }
      },
      required: [
        :customerUserId,
        :serviceId,
        :cleanerId,
        :scheduledDate,
        :scheduledTime,
        :address,
        :consentConfirmed
      ]
    })
  end

  defmodule AdminExtraTask do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminExtraTask",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        label: %Schema{type: :string},
        hours: %Schema{type: :number, minimum: 0}
      },
      required: [:id, :label, :hours]
    })
  end

  defmodule AdminExtraTaskList do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminExtraTaskList",
      type: :object,
      properties: %{
        tasks: %Schema{type: :array, items: AdminExtraTask}
      },
      required: [:tasks]
    })
  end

  defmodule AdminVisitHours do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminVisitHours",
      type: :object,
      description: "Visit length computed by direct_visit_hours.",
      properties: %{
        durationHours: %Schema{type: :number, minimum: 0.5},
        homeSize: %Schema{type: :string}
      },
      required: [:durationHours, :homeSize]
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
        createdByAdmin: %Schema{type: :boolean},
        notificationsSent: %Schema{type: :boolean},
        count: %Schema{type: :integer, minimum: 1},
        bookings: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              status: %Schema{type: :string},
              paymentStatus: %Schema{type: :string},
              amountMinor: %Schema{type: :integer, minimum: 0},
              currency: %Schema{type: :string},
              scheduledDate: %Schema{type: :string, format: :date}
            }
          }
        }
      },
      required: [
        :id,
        :status,
        :paymentStatus,
        :amountMinor,
        :currency,
        :customerUserId,
        :source,
        :createdByAdmin,
        :notificationsSent,
        :count,
        :bookings
      ]
    })
  end

  defmodule AdminServiceRequestItem do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectRequirements
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
        relatedServiceId: %Schema{type: :integer, nullable: true},
        requirements: DirectRequirements,
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
        :relatedServiceId,
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
        neededBy: %Schema{type: :string, format: :"date-time", nullable: true},
        sendNotifications: %Schema{
          type: :boolean,
          default: true,
          description: "When true, notify the customer and assigned worker after assignment."
        },
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
          enum: ~w(submitted triaging matching resolved cancelled)
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
        assignedWorkerUserId: %Schema{type: :string, format: :uuid, nullable: true},
        notificationsSent: %Schema{type: :boolean, nullable: true}
      },
      required: [:id, :status]
    })
  end
end
