defmodule MithrilWeb.Schemas.DirectDispatch.AdminUpdateServiceRequestRequestV2 do
  @moduledoc "OpenAPI schema for valid Direct dispatch status transitions."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "DirectAdminUpdateServiceRequestRequest",
    type: :object,
    properties: %{
      status: %Schema{
        type: :string,
        enum: ~w(triaging matching resolved cancelled)
      },
      adminNote: %Schema{type: :string, maxLength: 2000, nullable: true}
    },
    required: [:status]
  })
end
