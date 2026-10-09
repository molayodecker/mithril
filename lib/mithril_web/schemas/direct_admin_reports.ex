defmodule MithrilWeb.Schemas.DirectAdminReports do
  @moduledoc "OpenAPI schemas for Direct admin operations reports."

  defmodule Summary do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminReportsSummary",
      type: :object,
      properties: %{
        days: %Schema{type: :integer},
        currency: %Schema{type: :string},
        generatedAt: %Schema{type: :string, format: :"date-time"},
        revenueMinor: %Schema{type: :integer},
        revenueGrowthPercent: %Schema{type: :number, nullable: true},
        bookingsCount: %Schema{type: :integer},
        cancelRatePercent: %Schema{type: :number},
        fillRatePercent: %Schema{type: :number},
        avgOrderMinor: %Schema{type: :integer},
        dailyRevenue: %Schema{type: :array, items: %Schema{type: :object}},
        topAreas: %Schema{type: :array, items: %Schema{type: :object}}
      },
      required: [:days, :currency, :revenueMinor, :bookingsCount]
    })
  end

  defmodule SummaryResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminReports.Summary

    OpenApiSpex.schema(%{
      title: "DirectAdminReportsSummaryResponse",
      type: :object,
      properties: %{summary: Summary},
      required: [:summary]
    })
  end
end
