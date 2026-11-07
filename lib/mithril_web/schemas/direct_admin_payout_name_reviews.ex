defmodule MithrilWeb.Schemas.DirectAdminPayoutNameReviews do
  @moduledoc false

  defmodule Review do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPayoutNameReview",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        userId: %Schema{type: :string, format: :uuid},
        cleanerName: %Schema{type: :string, nullable: true},
        profileName: %Schema{type: :string, nullable: true},
        accountName: %Schema{type: :string, nullable: true},
        submittedName: %Schema{type: :string, nullable: true},
        namesMatch: %Schema{type: :boolean},
        status: %Schema{type: :string, enum: ["pending", "approved", "rejected"]},
        purpose: %Schema{type: :string},
        payoutType: %Schema{type: :string},
        maskedAccount: %Schema{type: :string, nullable: true},
        reviewNotes: %Schema{type: :string, nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true},
        reviewedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :userId, :namesMatch, :status]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminPayoutNameReviews.Review
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPayoutNameReviewList",
      type: :object,
      properties: %{
        reviews: %Schema{type: :array, items: Review}
      },
      required: [:reviews]
    })
  end

  defmodule Decision do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPayoutNameReviewDecision",
      type: :object,
      properties: %{
        decision: %Schema{type: :string, enum: ["approve", "reject"]},
        reviewNotes: %Schema{type: :string, nullable: true}
      },
      required: [:decision]
    })
  end

  defmodule DecisionResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPayoutNameReviewDecisionResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        namesMatch: %Schema{type: :boolean},
        recipientCreated: %Schema{type: :boolean}
      },
      required: [:id, :status, :namesMatch, :recipientCreated]
    })
  end
end
