defmodule MithrilWeb.Schemas.AccountCompletionOfferResponse do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "DirectAccountCompletionOfferResponse",
    type: :object,
    required: [:offered, :failed, :remaining],
    properties: %{
      offered: %Schema{type: :integer, description: "WhatsApp messages sent on this click"},
      failed: %Schema{type: :integer, description: "Numbers that could not be reached"},
      remaining: %Schema{
        type: :integer,
        description: "Open drafts with a phone that still have not been offered"
      }
    }
  })
end
