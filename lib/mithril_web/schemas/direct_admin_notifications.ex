defmodule MithrilWeb.Schemas.DirectAdminNotifications do
  @moduledoc "OpenAPI schemas for Direct admin notifications."

  defmodule Target do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationTarget",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true}
      },
      required: [:id, :name]
    })
  end

  defmodule TargetListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminNotifications.Target
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationTargetListResponse",
      type: :object,
      properties: %{targets: %Schema{type: :array, items: Target}},
      required: [:targets]
    })
  end

  defmodule Delivery do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationDelivery",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        recipientName: %Schema{type: :string},
        recipientEmail: %Schema{type: :string, nullable: true},
        recipientPhone: %Schema{type: :string, nullable: true},
        title: %Schema{type: :string},
        message: %Schema{type: :string},
        type: %Schema{type: :string},
        read: %Schema{type: :boolean},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true},
        screen: %Schema{type: :string, nullable: true}
      },
      required: [:id, :recipientName, :title, :message, :type, :read]
    })
  end

  defmodule DeliveryListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminNotifications.Delivery
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationDeliveryListResponse",
      type: :object,
      properties: %{
        deliveries: %Schema{type: :array, items: Delivery},
        page: %Schema{type: :integer, minimum: 1},
        limit: %Schema{type: :integer, minimum: 1, maximum: 100},
        total: %Schema{type: :integer, minimum: 0},
        totalPages: %Schema{type: :integer, minimum: 1}
      },
      required: [:deliveries, :page, :limit, :total, :totalPages]
    })
  end

  defmodule SendRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationSendRequest",
      type: :object,
      properties: %{
        targetUserId: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string, maxLength: 120},
        message: %Schema{type: :string, maxLength: 2000},
        type: %Schema{type: :string, default: "admin_message"},
        screen: %Schema{type: :string, maxLength: 120, nullable: true},
        includeSms: %Schema{type: :boolean, default: false},
        includeWhatsapp: %Schema{type: :boolean, default: false}
      },
      required: [:targetUserId, :title, :message]
    })
  end

  defmodule SendResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationSendResponse",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        inboxCreated: %Schema{type: :boolean},
        smsSent: %Schema{type: :boolean},
        whatsappSent: %Schema{type: :boolean}
      },
      required: [:ok, :inboxCreated, :smsSent, :whatsappSent]
    })
  end

  defmodule BroadcastPreviewResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationBroadcastPreviewResponse",
      type: :object,
      properties: %{
        segment: %Schema{type: :string, enum: ["customers", "cleaners", "all_app_users"]},
        segmentTotalCount: %Schema{type: :integer, minimum: 0},
        selectedForRun: %Schema{type: :integer, minimum: 0, maximum: 100},
        withPhoneCount: %Schema{type: :integer, minimum: 0},
        capped: %Schema{type: :boolean}
      },
      required: [:segment, :segmentTotalCount, :selectedForRun, :withPhoneCount, :capped]
    })
  end

  defmodule BroadcastRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationBroadcastRequest",
      type: :object,
      properties: %{
        segment: %Schema{type: :string, enum: ["customers", "cleaners", "all_app_users"]},
        title: %Schema{type: :string, maxLength: 120},
        message: %Schema{type: :string, maxLength: 2000},
        type: %Schema{type: :string, default: "admin_message"},
        screen: %Schema{type: :string, maxLength: 120, nullable: true},
        includeSms: %Schema{type: :boolean, default: false},
        includeWhatsapp: %Schema{type: :boolean, default: false}
      },
      required: [:segment, :title, :message]
    })
  end

  defmodule BroadcastResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminNotificationBroadcastResponse",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        attempted: %Schema{type: :integer, minimum: 0},
        inboxCreated: %Schema{type: :integer, minimum: 0},
        smsSent: %Schema{type: :integer, minimum: 0},
        whatsappSent: %Schema{type: :integer, minimum: 0},
        capped: %Schema{type: :boolean}
      },
      required: [:ok, :attempted, :inboxCreated, :smsSent, :whatsappSent, :capped]
    })
  end
end
