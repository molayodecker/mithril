defmodule MithrilWeb.Schemas.DirectAdminTwilio do
  @moduledoc false

  defmodule Message do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTwilioMessage",
      type: :object,
      properties: %{
        sid: %Schema{type: :string},
        from: %Schema{type: :string, nullable: true},
        to: %Schema{type: :string, nullable: true},
        body: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, nullable: true},
        direction: %Schema{type: :string, nullable: true},
        errorCode: %Schema{type: :integer, nullable: true},
        errorMessage: %Schema{type: :string, nullable: true},
        dateSent: %Schema{type: :string, nullable: true},
        dateCreated: %Schema{type: :string, nullable: true},
        numSegments: %Schema{type: :string, nullable: true}
      },
      required: [:sid]
    })
  end

  defmodule MessageLogResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminTwilio.Message
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminTwilioMessageLogResponse",
      type: :object,
      properties: %{
        messages: %Schema{type: :array, items: Message},
        nextPageToken: %Schema{type: :string, nullable: true}
      },
      required: [:messages]
    })
  end
end
