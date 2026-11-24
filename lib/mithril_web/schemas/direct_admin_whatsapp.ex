defmodule MithrilWeb.Schemas.DirectAdminWhatsApp do
  @moduledoc "OpenAPI schemas for the Direct admin WhatsApp inbox."

  defmodule Thread do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppThread",
      type: :object,
      properties: %{
        phoneE164: %Schema{type: :string},
        lastAt: %Schema{type: :string, format: :"date-time"},
        preview: %Schema{type: :string},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        displayLabel: %Schema{type: :string}
      },
      required: [:phoneE164, :lastAt, :preview, :displayLabel]
    })
  end

  defmodule ThreadListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminWhatsApp.Thread
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppThreadListResponse",
      type: :object,
      properties: %{threads: %Schema{type: :array, items: Thread}},
      required: [:threads]
    })
  end

  defmodule Message do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppMessage",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        direction: %Schema{type: :string, enum: ["inbound", "outbound"]},
        phoneE164: %Schema{type: :string},
        body: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        sentByUserId: %Schema{type: :string, format: :uuid, nullable: true},
        businessPhoneE164: %Schema{type: :string, nullable: true}
      },
      required: [:id, :direction, :phoneE164, :body, :createdAt]
    })
  end

  defmodule MessageListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminWhatsApp.Message
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppMessageListResponse",
      type: :object,
      properties: %{messages: %Schema{type: :array, items: Message}},
      required: [:messages]
    })
  end

  defmodule SendRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppSendRequest",
      type: :object,
      properties: %{
        phoneE164: %Schema{type: :string},
        body: %Schema{type: :string, maxLength: 2000},
        businessPhoneE164: %Schema{type: :string, nullable: true}
      },
      required: [:phoneE164, :body]
    })
  end

  defmodule BookingOfferRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppBookingOfferRequest",
      type: :object,
      properties: %{
        customerUserId: %Schema{type: :string, format: :uuid},
        serviceId: %Schema{type: :integer, minimum: 1},
        amountMinor: %Schema{type: :integer, minimum: 100},
        address: %Schema{type: :string, minLength: 3, maxLength: 500},
        latitude: %Schema{type: :number, nullable: true},
        longitude: %Schema{type: :number, nullable: true},
        durationHours: %Schema{type: :number, nullable: true, minimum: 1, maximum: 24}
      },
      required: [:customerUserId, :serviceId, :amountMinor, :address]
    })
  end

  defmodule BookingOfferScheduleRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppBookingOfferScheduleRequest",
      type: :object,
      properties: %{
        scheduledDate: %Schema{type: :string, format: :date},
        scheduledTime: %Schema{type: :string}
      },
      required: [:scheduledDate, :scheduledTime]
    })
  end

  defmodule BookingOfferSlot do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppBookingOfferSlot",
      type: :object,
      properties: %{
        index: %Schema{type: :integer},
        date: %Schema{type: :string},
        time: %Schema{type: :string},
        label: %Schema{type: :string}
      }
    })
  end

  defmodule BookingOfferResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppBookingOffer",
      type: :object,
      properties: %{
        offerId: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        customerUserId: %Schema{type: :string, format: :uuid},
        phoneE164: %Schema{type: :string},
        serviceId: %Schema{type: :integer},
        serviceName: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        address: %Schema{type: :string},
        bookingId: %Schema{type: :string, format: :uuid, nullable: true},
        cleanerName: %Schema{type: :string, nullable: true},
        scheduledDate: %Schema{type: :string, nullable: true},
        scheduledTime: %Schema{type: :string, nullable: true},
        reply: %Schema{type: :string, nullable: true},
        slots: %Schema{type: :array, items: BookingOfferSlot}
      },
      required: [:offerId, :status, :amountMinor, :currency]
    })
  end

  defmodule CustomerRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppCustomerRequest",
      type: :object,
      properties: %{
        phoneE164: %Schema{type: :string},
        name: %Schema{type: :string, minLength: 1, maxLength: 80}
      },
      required: [:phoneE164, :name]
    })
  end

  defmodule CustomerResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppCustomer",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        phoneE164: %Schema{type: :string},
        created: %Schema{type: :boolean}
      },
      required: [:userId, :name, :phoneE164, :created]
    })
  end

  defmodule MutationResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppMutationResponse",
      type: :object,
      properties: %{ok: %Schema{type: :boolean}},
      required: [:ok]
    })
  end
end
