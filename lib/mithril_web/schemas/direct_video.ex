defmodule MithrilWeb.Schemas.DirectVideo do
  @moduledoc "OpenAPI schemas for Direct candidate video introductions."

  defmodule CandidateVideoResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCandidateVideoResponse",
      type: :object,
      properties: %{
        candidateUserId: %Schema{type: :string, format: :uuid},
        introVideoUrl: %Schema{type: :string, format: :uri, nullable: true},
        introVideoThumbnailUrl: %Schema{type: :string, format: :uri, nullable: true},
        introVideoTitle: %Schema{type: :string, maxLength: 120, nullable: true}
      },
      required: [
        :candidateUserId,
        :introVideoUrl,
        :introVideoThumbnailUrl,
        :introVideoTitle
      ]
    })
  end

  defmodule UpdateCandidateVideoRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectUpdateCandidateVideoRequest",
      type: :object,
      properties: %{
        introVideoUrl: %Schema{type: :string, format: :uri, nullable: true},
        introVideoThumbnailUrl: %Schema{type: :string, format: :uri, nullable: true},
        introVideoTitle: %Schema{type: :string, maxLength: 120, nullable: true}
      },
      required: [:introVideoUrl]
    })
  end
end
