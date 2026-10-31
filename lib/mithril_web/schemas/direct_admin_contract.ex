defmodule MithrilWeb.Schemas.DirectAdminContract do
  @moduledoc "OpenAPI schemas for ongoing client contracts, advances, payday, and invoices."

  defmodule Week do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractWeek",
      type: :object,
      properties: %{
        date: %Schema{type: :string, format: :date},
        label: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["paid", "due", "upcoming"]},
        reference: %Schema{type: :string, nullable: true}
      },
      required: [:date, :label, :status]
    })
  end

  defmodule Assignment do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractAssignment",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        workerId: %Schema{type: :string, format: :uuid},
        workerName: %Schema{type: :string},
        phone: %Schema{type: :string, nullable: true},
        walletBalanceMinor: %Schema{type: :integer, nullable: true},
        status: %Schema{type: :string, enum: ["active", "ended"]},
        roleLabel: %Schema{type: :string},
        monthlyPayMinor: %Schema{type: :integer},
        clientRateMinor: %Schema{type: :integer},
        weeklyAdvanceMinor: %Schema{type: :integer, nullable: true},
        advanceWeekday: %Schema{type: :integer, nullable: true, minimum: 0, maximum: 6},
        advanceWeekdayLabel: %Schema{type: :string, nullable: true},
        advanceMode: %Schema{type: :string, enum: ["manual", "automatic"]},
        weeks: %Schema{type: :array, items: Week},
        advancesPaidMinor: %Schema{type: :integer},
        advancesPaidCount: %Schema{type: :integer},
        netMinor: %Schema{type: :integer},
        dueCount: %Schema{type: :integer},
        nextDueOn: %Schema{type: :string, format: :date, nullable: true}
      },
      required: [
        :id,
        :workerId,
        :workerName,
        :status,
        :roleLabel,
        :monthlyPayMinor,
        :clientRateMinor,
        :advanceMode,
        :weeks,
        :advancesPaidMinor,
        :netMinor
      ]
    })
  end

  defmodule Summary do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractSummary",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ["active", "ended"]},
        clientName: %Schema{type: :string},
        clientKind: %Schema{type: :string, enum: ["company", "person"]},
        billingContact: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string, nullable: true},
        monthlyFeeMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        workerPayMinor: %Schema{type: :integer},
        marginMinor: %Schema{type: :integer},
        advancesPaidMinor: %Schema{type: :integer},
        netDueMinor: %Schema{type: :integer},
        dueAdvanceCount: %Schema{type: :integer},
        paydayClosed: %Schema{type: :boolean},
        workers: %Schema{type: :array, items: Assignment},
        invoiceStatus: %Schema{
          type: :string,
          enum: ["not_invoiced", "not_yet_due", "saved", "sent_email", "sent_whatsapp"]
        },
        invoiceNo: %Schema{type: :string, nullable: true}
      },
      required: [
        :id,
        :status,
        :clientName,
        :clientKind,
        :monthlyFeeMinor,
        :currency,
        :workers,
        :invoiceStatus
      ]
    })
  end

  defmodule List do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractList",
      type: :object,
      properties: %{
        month: %Schema{type: :string, example: "2026-10"},
        periodLabel: %Schema{type: :string},
        today: %Schema{type: :string, format: :date},
        payday: %Schema{type: :string, format: :date},
        paydayLabel: %Schema{type: :string},
        dueAdvanceCount: %Schema{type: :integer},
        contracts: %Schema{type: :array, items: Summary}
      },
      required: [
        :month,
        :periodLabel,
        :today,
        :payday,
        :paydayLabel,
        :dueAdvanceCount,
        :contracts
      ]
    })
  end

  defmodule Advance do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractAdvance",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        weekOn: %Schema{type: :string, format: :date},
        weekLabel: %Schema{type: :string},
        workerName: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        paidVia: %Schema{type: :string, enum: ["manual", "automatic"]},
        paidByName: %Schema{type: :string},
        reference: %Schema{type: :string}
      },
      required: [
        :id,
        :weekOn,
        :weekLabel,
        :workerName,
        :amountMinor,
        :paidVia,
        :paidByName,
        :reference
      ]
    })
  end

  defmodule InvoiceMonth do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractInvoiceMonth",
      type: :object,
      properties: %{
        month: %Schema{type: :string},
        monthLabel: %Schema{type: :string},
        invoiceNo: %Schema{type: :string, nullable: true},
        amountMinor: %Schema{type: :integer},
        status: %Schema{
          type: :string,
          enum: ["not_invoiced", "not_yet_due", "saved", "sent_email", "sent_whatsapp"]
        },
        id: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:month, :monthLabel, :amountMinor, :status]
    })
  end

  defmodule Client do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractClient",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        kind: %Schema{type: :string, enum: ["company", "person"]},
        billingContact: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string, nullable: true}
      },
      required: [:name, :kind]
    })
  end

  defmodule Detail do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractDetail",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        clientName: %Schema{type: :string},
        clientKind: %Schema{type: :string, enum: ["company", "person"]},
        billingContact: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string, nullable: true},
        monthlyFeeMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        workerPayMinor: %Schema{type: :integer},
        marginMinor: %Schema{type: :integer},
        advancesPaidMinor: %Schema{type: :integer},
        netDueMinor: %Schema{type: :integer},
        dueAdvanceCount: %Schema{type: :integer},
        paydayClosed: %Schema{type: :boolean},
        workers: %Schema{type: :array, items: Assignment},
        invoiceStatus: %Schema{type: :string},
        invoiceNo: %Schema{type: :string, nullable: true},
        month: %Schema{type: :string},
        periodLabel: %Schema{type: :string},
        payday: %Schema{type: :string, format: :date},
        paydayLabel: %Schema{type: :string},
        today: %Schema{type: :string, format: :date},
        client: Client,
        placementId: %Schema{type: :string, format: :uuid, nullable: true},
        invoices: %Schema{type: :array, items: InvoiceMonth},
        advances: %Schema{type: :array, items: Advance}
      },
      required: [
        :id,
        :clientName,
        :monthlyFeeMinor,
        :currency,
        :workers,
        :client,
        :invoices,
        :advances
      ]
    })
  end

  defmodule WriteClient do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractWriteRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        kind: %Schema{type: :string, enum: ["company", "person"]},
        billingContact: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string, nullable: true},
        monthlyFeeMinor: %Schema{type: :integer, minimum: 1},
        placementId: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:name, :kind, :monthlyFeeMinor]
    })
  end

  defmodule Created do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractCreated",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        clientId: %Schema{type: :string, format: :uuid}
      },
      required: [:id]
    })
  end

  defmodule AssignmentRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractAssignmentRequest",
      type: :object,
      properties: %{
        workerId: %Schema{type: :string, format: :uuid},
        roleLabel: %Schema{type: :string},
        monthlyPayMinor: %Schema{type: :integer, minimum: 1},
        clientRateMinor: %Schema{type: :integer, minimum: 0},
        weeklyAdvanceMinor: %Schema{type: :integer, nullable: true, minimum: 1},
        advanceWeekday: %Schema{type: :integer, nullable: true, minimum: 0, maximum: 6},
        advanceMode: %Schema{type: :string, enum: ["manual", "automatic"], nullable: true}
      },
      required: [:roleLabel, :monthlyPayMinor, :clientRateMinor]
    })
  end

  defmodule AdvanceRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractAdvanceRequest",
      type: :object,
      properties: %{
        assignmentId: %Schema{type: :string, format: :uuid},
        weekOn: %Schema{type: :string, format: :date}
      },
      required: [:assignmentId, :weekOn]
    })
  end

  defmodule AdvanceResult do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractAdvanceResult",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        reference: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        newBalanceMinor: %Schema{type: :integer, nullable: true},
        weekOn: %Schema{type: :string, format: :date}
      },
      required: [:id, :reference, :amountMinor, :weekOn]
    })
  end

  defmodule PayDueRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractPayDueRequest",
      type: :object,
      properties: %{
        month: %Schema{type: :string, example: "2026-10"},
        contractId: %Schema{type: :string, format: :uuid, nullable: true}
      }
    })
  end

  defmodule PayDueResult do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractPayDueResult",
      type: :object,
      properties: %{
        paidCount: %Schema{type: :integer},
        totalMinor: %Schema{type: :integer}
      },
      required: [:paidCount, :totalMinor]
    })
  end

  defmodule PaydayRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractPaydayRequest",
      type: :object,
      properties: %{
        month: %Schema{type: :string, example: "2026-10"}
      },
      required: [:month]
    })
  end

  defmodule PaydayLine do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractPaydayLine",
      type: :object,
      properties: %{
        workerName: %Schema{type: :string},
        grossMinor: %Schema{type: :integer},
        advancesMinor: %Schema{type: :integer},
        netMinor: %Schema{type: :integer}
      },
      required: [:workerName, :grossMinor, :advancesMinor, :netMinor]
    })
  end

  defmodule PaydayResult do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractPaydayResult",
      type: :object,
      properties: %{
        contractId: %Schema{type: :string, format: :uuid},
        month: %Schema{type: :string},
        totalNetMinor: %Schema{type: :integer},
        lines: %Schema{type: :array, items: PaydayLine}
      },
      required: [:contractId, :month, :totalNetMinor, :lines]
    })
  end

  defmodule InvoiceRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractInvoiceRequest",
      type: :object,
      properties: %{
        month: %Schema{type: :string, example: "2026-10"},
        style: %Schema{type: :string, enum: ["one_line", "per_worker"]},
        channel: %Schema{type: :string, enum: ["email", "whatsapp"]}
      },
      required: [:month, :style, :channel]
    })
  end

  defmodule InvoiceResult do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractInvoiceResult",
      type: :object,
      properties: %{
        invoiceNo: %Schema{type: :string},
        totalMinor: %Schema{type: :integer},
        channel: %Schema{type: :string, enum: ["email", "whatsapp"]},
        sent: %Schema{type: :boolean}
      },
      required: [:invoiceNo, :totalMinor, :channel, :sent]
    })
  end

  defmodule Worker do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractWorker",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        phone: %Schema{type: :string, nullable: true},
        walletBalanceMinor: %Schema{type: :integer, nullable: true}
      },
      required: [:userId, :name]
    })
  end

  defmodule WorkerList do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractWorkerList",
      type: :object,
      properties: %{
        workers: %Schema{type: :array, items: Worker}
      },
      required: [:workers]
    })
  end

  defmodule PublicLine do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectContractInvoiceLine",
      type: :object,
      properties: %{
        description: %Schema{type: :string},
        amountMinor: %Schema{type: :integer}
      },
      required: [:description, :amountMinor]
    })
  end

  defmodule PublicInvoice do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectContractInvoice",
      type: :object,
      properties: %{
        invoiceNo: %Schema{type: :string},
        issuedOn: %Schema{type: :string, format: :date},
        dueOn: %Schema{type: :string, format: :date},
        totalMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        billToName: %Schema{type: :string},
        billingContact: %Schema{type: :string, nullable: true},
        billToPhone: %Schema{type: :string, nullable: true},
        billToEmail: %Schema{type: :string, nullable: true},
        project: %Schema{type: :string},
        notes: %Schema{type: :string, nullable: true},
        lines: %Schema{type: :array, items: PublicLine}
      },
      required: [
        :invoiceNo,
        :issuedOn,
        :dueOn,
        :totalMinor,
        :currency,
        :billToName,
        :project,
        :lines
      ]
    })
  end

  defmodule IdResult do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminContractIdResult",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        endedOn: %Schema{type: :string, format: :date, nullable: true}
      },
      required: [:id]
    })
  end
end
