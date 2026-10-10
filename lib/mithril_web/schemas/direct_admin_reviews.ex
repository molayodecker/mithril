defmodule MithrilWeb.Schemas.DirectAdminReviews do
  @moduledoc false

  defmodule Stats do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminReviewStats",
      type: :object,
      properties: %{
        averageRating: %Schema{type: :number},
        thisMonthCount: %Schema{type: :integer},
        lowRatingCount: %Schema{type: :integer},
        needsReplyCount: %Schema{type: :integer}
      }
    })
  end

  defmodule Review do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminReview",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        bookingId: %Schema{type: :string, format: :uuid, nullable: true},
        rating: %Schema{type: :integer},
        comment: %Schema{type: :string, nullable: true},
        reviewerName: %Schema{type: :string},
        revieweeName: %Schema{type: :string}
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminReviews.{Review, Stats}
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminReviewsListResponse",
      type: :object,
      properties: %{
        stats: Stats,
        reviews: %Schema{type: :array, items: Review}
      },
      required: [:stats, :reviews]
    })
  end
end
