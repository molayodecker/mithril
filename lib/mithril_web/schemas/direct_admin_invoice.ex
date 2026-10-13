defmodule MithrilWeb.Schemas.DirectAdminInvoice do
  @moduledoc "OpenAPI schemas for job invoices."

  defmodule Line do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminJobInvoiceLine",
      type: :object,
      properties: %{
        description: %Schema{type: :string, minLength: 1, maxLength: 200},
        qty: %Schema{type: :integer, nullable: true, minimum: 1, maximum: 10_000},
        days: %Schema{type: :integer, nullable: true, minimum: 1, maximum: 10_000},
        unitMinor: %Schema{type: :integer, minimum: 1},
        totalMinor: %Schema{type: :integer, nullable: true}
      },
      required: [:description, :unitMinor]
    })
  end

  defmodule Invoice do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminJobInvoice",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        bookingId: %Schema{type: :string, format: :uuid},
        invoiceNo: %Schema{type: :string},
        issuedOn: %Schema{type: :string, format: :date},
        billToName: %Schema{type: :string},
        billToAddress: %Schema{type: :string, nullable: true},
        billToPhone: %Schema{type: :string, nullable: true},
        billToEmail: %Schema{type: :string, nullable: true},
        project: %Schema{type: :string},
        lines: %Schema{type: :array, items: Line},
        adjustmentMinor: %Schema{type: :integer},
        subtotalMinor: %Schema{type: :integer},
        totalMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        notes: %Schema{type: :string, nullable: true},
        signatoryRole: %Schema{type: :string, maxLength: 80, nullable: true},
        viewUrl: %Schema{type: :string, nullable: true},
        lastWhatsappSentAt: %Schema{type: :string, format: :"date-time", nullable: true},
        lastEmailSentAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [
        :id,
        :bookingId,
        :invoiceNo,
        :issuedOn,
        :billToName,
        :project,
        :lines,
        :adjustmentMinor,
        :subtotalMinor,
        :totalMinor,
        :currency
      ]
    })
  end

  defmodule UpsertRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminJobInvoiceUpsertRequest",
      type: :object,
      properties: %{
        invoiceNo: %Schema{type: :string, maxLength: 40, nullable: true},
        issuedOn: %Schema{type: :string, format: :date},
        billToName: %Schema{type: :string, minLength: 1, maxLength: 160},
        billToAddress: %Schema{type: :string, maxLength: 500, nullable: true},
        billToPhone: %Schema{type: :string, maxLength: 32, nullable: true},
        billToEmail: %Schema{type: :string, maxLength: 200, nullable: true},
        project: %Schema{type: :string, minLength: 1, maxLength: 160},
        lines: %Schema{
          type: :array,
          minItems: 1,
          maxItems: 20,
          items: %Schema{
            type: :object,
            properties: %{
              description: %Schema{type: :string, minLength: 1, maxLength: 200},
              qty: %Schema{type: :integer, nullable: true, minimum: 1, maximum: 10_000},
              days: %Schema{type: :integer, nullable: true, minimum: 1, maximum: 10_000},
              unitMinor: %Schema{type: :integer, minimum: 1}
            },
            required: [:description, :unitMinor]
          }
        },
        adjustmentMinor: %Schema{type: :integer},
        notes: %Schema{type: :string, maxLength: 2000, nullable: true},
        signatoryRole: %Schema{type: :string, maxLength: 80, nullable: true}
      },
      required: [:issuedOn, :billToName, :project, :lines, :adjustmentMinor]
    })
  end

  defmodule SendRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminJobInvoiceSendRequest",
      type: :object,
      properties: %{
        channel: %Schema{type: :string, enum: ["whatsapp", "email"]}
      },
      required: [:channel]
    })
  end

  defmodule SendResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminJobInvoiceSendResponse",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        channel: %Schema{type: :string, enum: ["whatsapp", "email"]},
        sent: %Schema{type: :boolean}
      },
      required: [:ok, :channel, :sent]
    })
  end
end
