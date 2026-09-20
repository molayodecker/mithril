defmodule MithrilWeb.Schemas.DirectAdminWhatsApp do
  @moduledoc "OpenAPI schemas for the Direct admin WhatsApp inbox."

  defmodule Thread do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppThread",
      type: :object,
      properties: %{
        phoneE164: %Schema{type: :string},
        lastAt: %Schema{type: :string, format: :"date-time"},
        preview: %Schema{type: :string},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        displayLabel: %Schema{type: :string}
      },
      required: [:phoneE164, :lastAt, :preview, :displayLabel]
    })
  end

  defmodule ThreadListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminWhatsApp.Thread
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppThreadListResponse",
      type: :object,
      properties: %{threads: %Schema{type: :array, items: Thread}},
      required: [:threads]
    })
  end

  defmodule Message do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppMessage",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        direction: %Schema{type: :string, enum: ["inbound", "outbound"]},
        phoneE164: %Schema{type: :string},
        body: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        sentByUserId: %Schema{type: :string, format: :uuid, nullable: true},
        businessPhoneE164: %Schema{type: :string, nullable: true}
      },
      required: [:id, :direction, :phoneE164, :body, :createdAt]
    })
  end

  defmodule MessageListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminWhatsApp.Message
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppMessageListResponse",
      type: :object,
      properties: %{messages: %Schema{type: :array, items: Message}},
      required: [:messages]
    })
  end

  defmodule SendRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppSendRequest",
      type: :object,
      properties: %{
        phoneE164: %Schema{type: :string},
        body: %Schema{type: :string, maxLength: 2000},
        businessPhoneE164: %Schema{type: :string, nullable: true}
      },
      required: [:phoneE164, :body]
    })
  end

  defmodule MutationResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWhatsAppMutationResponse",
      type: :object,
      properties: %{ok: %Schema{type: :boolean}},
      required: [:ok]
    })
  end
end
