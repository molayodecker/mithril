defmodule MithrilWeb.Schemas.DirectAdminPayouts do
  @moduledoc false

  defmodule Summary do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPayoutsSummary",
      type: :object,
      properties: %{
        currency: %Schema{type: :string},
        owedMinor: %Schema{type: :integer},
        cleanersWithBalance: %Schema{type: :integer},
        pendingCount: %Schema{type: :integer},
        pendingMinor: %Schema{type: :integer},
        paidThisWeekMinor: %Schema{type: :integer}
      }
    })
  end

  defmodule Payout do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPayout",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        cleanerUserId: %Schema{type: :string, format: :uuid},
        cleanerName: %Schema{type: :string},
        amountMinor: %Schema{type: :integer},
        status: %Schema{type: :string},
        payoutMethodLabel: %Schema{type: :string}
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminPayouts.{Payout, Summary}
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPayoutsListResponse",
      type: :object,
      properties: %{
        summary: Summary,
        payouts: %Schema{type: :array, items: Payout}
      },
      required: [:summary, :payouts]
    })
  end
end
