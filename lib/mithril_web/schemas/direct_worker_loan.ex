defmodule MithrilWeb.Schemas.DirectWorkerLoan do
  @moduledoc "OpenAPI schemas for worker loan requests."

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectWorkerLoanRequest",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        workerId: %Schema{type: :string, format: :uuid},
        workerLabel: %Schema{type: :string, nullable: true},
        amountMinor: %Schema{type: :integer},
        reason: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: ["pending", "approved", "rejected", "cancelled"]},
        reviewNotes: %Schema{type: :string, nullable: true},
        reviewedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true},
        outstandingMinor: %Schema{type: :integer, nullable: true}
      },
      required: [:id, :workerId, :amountMinor, :status]
    })
  end

  defmodule RequestList do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectWorkerLoan.Request
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectWorkerLoanRequestList",
      type: :object,
      properties: %{
        requests: %Schema{type: :array, items: Request}
      },
      required: [:requests]
    })
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectWorkerLoanCreateRequest",
      type: :object,
      properties: %{
        amountMinor: %Schema{type: :integer, minimum: 1},
        reason: %Schema{type: :string, maxLength: 500, nullable: true}
      },
      required: [:amountMinor]
    })
  end

  defmodule ReviewRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectWorkerLoanReviewRequest",
      type: :object,
      properties: %{
        decision: %Schema{type: :string, enum: ["approve", "reject"]},
        reviewNotes: %Schema{type: :string, maxLength: 500, nullable: true}
      },
      required: [:decision]
    })
  end

  defmodule ReviewResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectWorkerLoanReviewResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        workerId: %Schema{type: :string, format: :uuid},
        amountMinor: %Schema{type: :integer},
        status: %Schema{type: :string},
        newBalanceMinor: %Schema{type: :integer, nullable: true},
        outstandingMinor: %Schema{type: :integer, nullable: true}
      },
      required: [:id, :workerId, :amountMinor, :status]
    })
  end

  defmodule Summary do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectWorkerLoanSummary",
      type: :object,
      properties: %{
        outstandingMinor: %Schema{type: :integer},
        currency: %Schema{type: :string}
      },
      required: [:outstandingMinor, :currency]
    })
  end
end
