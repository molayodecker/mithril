defmodule MithrilWeb.Schemas.DirectPaymentRequest do
  @moduledoc "OpenAPI schemas for public payment requests."

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPaymentRequest",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        publicToken: %Schema{type: :string},
        payUrl: %Schema{type: :string},
        customerUserId: %Schema{type: :string, format: :uuid, nullable: true},
        customerName: %Schema{type: :string},
        phone: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        description: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["unpaid", "paid"]},
        channel: %Schema{type: :string, enum: ["whatsapp", "sms"], nullable: true},
        sent: %Schema{type: :boolean},
        deliveryError: %Schema{type: :string, nullable: true},
        sentAt: %Schema{type: :string, format: :"date-time", nullable: true},
        paidAt: %Schema{type: :string, format: :"date-time", nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true},
        remindIfUnpaid: %Schema{type: :boolean},
        remindersSent: %Schema{type: :integer, minimum: 0},
        reminderSentAt: %Schema{type: :string, format: :"date-time", nullable: true},
        reminderPaused: %Schema{type: :boolean},
        nextReminderAt: %Schema{type: :string, format: :"date-time", nullable: true},
        reminderError: %Schema{type: :string, nullable: true}
      },
      required: [
        :id,
        :publicToken,
        :payUrl,
        :customerName,
        :phone,
        :description,
        :amountMinor,
        :currency,
        :status,
        :sent,
        :remindIfUnpaid,
        :remindersSent,
        :reminderPaused
      ]
    })
  end

  defmodule List do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPaymentRequestList",
      type: :object,
      properties: %{
        requests: %Schema{type: :array, items: Request}
      },
      required: [:requests]
    })
  end

  defmodule Create do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPaymentRequestCreate",
      type: :object,
      properties: %{
        customerName: %Schema{type: :string, minLength: 1, maxLength: 160},
        phone: %Schema{type: :string, minLength: 1, maxLength: 32},
        description: %Schema{type: :string, minLength: 1, maxLength: 160},
        amountMinor: %Schema{type: :integer, minimum: 100, maximum: 2_147_483_647},
        customerUserId: %Schema{type: :string, format: :uuid, nullable: true},
        email: %Schema{type: :string, maxLength: 200, nullable: true},
        idempotencyKey: %Schema{type: :string, format: :uuid},
        remindIfUnpaid: %Schema{
          type: :boolean,
          default: false,
          description:
            "Send WhatsApp or text reminders if the request is still unpaid, after 24 hours, 48 hours, 72 hours, 7 days, 30 days, and 14 weeks."
        }
      },
      required: [:customerName, :phone, :description, :amountMinor, :idempotencyKey]
    })
  end

  defmodule Public do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPublicPaymentRequest",
      type: :object,
      properties: %{
        customerName: %Schema{type: :string},
        description: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["unpaid", "paid"]},
        paidAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:customerName, :description, :amountMinor, :currency, :status]
    })
  end

  defmodule CheckoutRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPublicPaymentCheckoutRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, maxLength: 200, nullable: true}
      }
    })
  end

  defmodule Checkout do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPublicPaymentCheckout",
      type: :object,
      properties: %{
        authorizationUrl: %Schema{type: :string},
        reference: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        status: %Schema{type: :string}
      },
      required: [:authorizationUrl, :reference, :amountMinor, :currency, :status]
    })
  end

  defmodule VerifyRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPublicPaymentVerifyRequest",
      type: :object,
      properties: %{
        reference: %Schema{type: :string, minLength: 1, maxLength: 100}
      },
      required: [:reference]
    })
  end
end
