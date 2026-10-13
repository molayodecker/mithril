defmodule MithrilWeb.Schemas.DirectAdminBilling do
  @moduledoc "OpenAPI schemas for custom invoices and payment advice."

  alias OpenApiSpex.Schema

  defmodule Invoice do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminInvoice.Line
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBillingInvoice",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        formType: %Schema{
          type: :string,
          enum: ["w8ben", "1099"],
          nullable: true,
          description: "Optional legacy value; payment advice uses the tax form instead"
        },
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
        signatoryRole: %Schema{type: :string, nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [
        :id,
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

  defmodule InvoiceList do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminBilling.Invoice
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBillingInvoiceList",
      type: :object,
      properties: %{
        invoices: %Schema{type: :array, items: Invoice}
      },
      required: [:invoices]
    })
  end

  defmodule InvoiceUpsertRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminBillingInvoiceUpsertRequest",
      type: :object,
      properties: %{
        formType: %Schema{
          type: :string,
          enum: ["w8ben", "1099"],
          nullable: true,
          description: "Ignored for new invoices; optional for legacy rows"
        },
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

  defmodule MoneyLine do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPaymentAdviceLine",
      type: :object,
      properties: %{
        description: %Schema{type: :string},
        reference: %Schema{type: :string, nullable: true},
        amountMinor: %Schema{type: :integer, minimum: 1}
      },
      required: [:description, :amountMinor]
    })
  end

  defmodule Advice do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminBilling.MoneyLine
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPaymentAdvice",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        formType: %Schema{
          type: :string,
          enum: ["w8ben", "1099"],
          description: "Form W-8BEN or 1099"
        },
        adviceNo: %Schema{type: :string},
        payPeriod: %Schema{type: :string},
        paymentDate: %Schema{type: :string, format: :date},
        paidToName: %Schema{type: :string},
        paidToAddress: %Schema{type: :string, nullable: true},
        paidToEmail: %Schema{type: :string, nullable: true},
        paidToPhone: %Schema{type: :string, nullable: true},
        employeeId: %Schema{type: :string, nullable: true},
        role: %Schema{type: :string, nullable: true},
        department: %Schema{type: :string, nullable: true},
        payType: %Schema{type: :string, nullable: true},
        earnings: %Schema{type: :array, items: MoneyLine},
        reimbursements: %Schema{type: :array, items: MoneyLine},
        deductions: %Schema{type: :array, items: MoneyLine},
        earningsMinor: %Schema{type: :integer},
        reimbursementsMinor: %Schema{type: :integer},
        deductionsMinor: %Schema{type: :integer},
        netMinor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        payMethod: %Schema{type: :string, nullable: true},
        payAccount: %Schema{type: :string, nullable: true},
        payNetwork: %Schema{type: :string, nullable: true},
        payReference: %Schema{type: :string, nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [
        :id,
        :formType,
        :adviceNo,
        :payPeriod,
        :paymentDate,
        :paidToName,
        :earnings,
        :reimbursements,
        :deductions,
        :earningsMinor,
        :reimbursementsMinor,
        :deductionsMinor,
        :netMinor,
        :currency
      ]
    })
  end

  defmodule AdviceList do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminBilling.Advice
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPaymentAdviceList",
      type: :object,
      properties: %{
        advices: %Schema{type: :array, items: Advice}
      },
      required: [:advices]
    })
  end

  defmodule AdviceUpsertRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPaymentAdviceUpsertRequest",
      type: :object,
      properties: %{
        formType: %Schema{
          type: :string,
          enum: ["w8ben", "1099"],
          description: "Form W-8BEN or 1099"
        },
        adviceNo: %Schema{type: :string, maxLength: 40, nullable: true},
        payPeriod: %Schema{type: :string, minLength: 1, maxLength: 40},
        paymentDate: %Schema{type: :string, format: :date},
        paidToName: %Schema{type: :string, minLength: 1, maxLength: 160},
        paidToAddress: %Schema{type: :string, maxLength: 500, nullable: true},
        paidToEmail: %Schema{type: :string, maxLength: 200, nullable: true},
        paidToPhone: %Schema{type: :string, maxLength: 32, nullable: true},
        employeeId: %Schema{type: :string, maxLength: 40, nullable: true},
        role: %Schema{type: :string, maxLength: 80, nullable: true},
        department: %Schema{type: :string, maxLength: 80, nullable: true},
        payType: %Schema{type: :string, maxLength: 80, nullable: true},
        earnings: %Schema{
          type: :array,
          minItems: 1,
          maxItems: 20,
          items: %Schema{
            type: :object,
            properties: %{
              description: %Schema{type: :string, minLength: 1, maxLength: 200},
              amountMinor: %Schema{type: :integer, minimum: 1}
            },
            required: [:description, :amountMinor]
          }
        },
        reimbursements: %Schema{
          type: :array,
          maxItems: 20,
          items: %Schema{
            type: :object,
            properties: %{
              description: %Schema{type: :string, minLength: 1, maxLength: 200},
              reference: %Schema{type: :string, maxLength: 40, nullable: true},
              amountMinor: %Schema{type: :integer, minimum: 1}
            },
            required: [:description, :amountMinor]
          }
        },
        deductions: %Schema{
          type: :array,
          maxItems: 20,
          items: %Schema{
            type: :object,
            properties: %{
              description: %Schema{type: :string, minLength: 1, maxLength: 200},
              amountMinor: %Schema{type: :integer, minimum: 1}
            },
            required: [:description, :amountMinor]
          }
        },
        payMethod: %Schema{type: :string, maxLength: 80, nullable: true},
        payAccount: %Schema{type: :string, maxLength: 40, nullable: true},
        payNetwork: %Schema{type: :string, maxLength: 40, nullable: true},
        payReference: %Schema{type: :string, maxLength: 40, nullable: true}
      },
      required: [:formType, :payPeriod, :paymentDate, :paidToName, :earnings]
    })
  end
end
