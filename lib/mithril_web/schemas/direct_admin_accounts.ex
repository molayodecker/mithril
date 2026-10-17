defmodule MithrilWeb.Schemas.DirectAdminAccounts do
  @moduledoc false

  defmodule MergeRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAccountMergeRequest",
      type: :object,
      properties: %{
        primaryUserId: %Schema{type: :string, format: :uuid},
        secondaryUserId: %Schema{type: :string, format: :uuid}
      },
      required: [:primaryUserId, :secondaryUserId]
    })
  end

  defmodule MergeResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminAccountMergeResponse",
      type: :object,
      properties: %{
        primaryUserId: %Schema{type: :string, format: :uuid},
        secondaryUserId: %Schema{type: :string, format: :uuid},
        snapshot: %Schema{type: :object}
      },
      required: [:primaryUserId, :secondaryUserId, :snapshot]
    })
  end
end
