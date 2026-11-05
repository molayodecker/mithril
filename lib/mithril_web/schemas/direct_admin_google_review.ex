defmodule MithrilWeb.Schemas.DirectAdminGoogleReview do
  @moduledoc false

  defmodule Request do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminGoogleReviewRequest",
      type: :object,
      properties: %{
        channel: %Schema{type: :string, enum: ["whatsapp", "email", "facebook"]}
      },
      required: [:channel]
    })
  end

  defmodule Result do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminGoogleReviewResult",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        channel: %Schema{type: :string, enum: ["whatsapp", "email", "facebook"]},
        sent: %Schema{type: :boolean},
        shareUrl: %Schema{type: :string, nullable: true}
      },
      required: [:ok, :channel, :sent]
    })
  end
end
