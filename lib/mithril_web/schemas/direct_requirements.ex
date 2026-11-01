defmodule MithrilWeb.Schemas.DirectRequirements do
  @moduledoc """
  Closed jsonb object for Direct dispatch and placement requests.

  `Mithril.DirectDispatch` and `Mithril.Direct` store this value and do not
  read keys from it. Clients send an empty object. Add a named property here
  before a client starts sending that key.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DirectRequirements",
    description:
      "Closed object. Dispatch and placement store this jsonb and do not interpret keys. Send an empty object until a named field is added on this schema.",
    type: :object,
    additionalProperties: false,
    properties: %{},
    default: %{}
  })
end
