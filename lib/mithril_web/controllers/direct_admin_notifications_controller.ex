defmodule MithrilWeb.DirectAdminNotificationsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminNotifications

  alias MithrilWeb.Schemas.DirectAdminNotifications.{
    BroadcastPreviewResponse,
    BroadcastRequest,
    BroadcastResponse,
    DeliveryListResponse,
    SendRequest,
    SendResponse,
    TargetListResponse
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-notifications"])

  operation(:index,
    operation_id: "direct.listAdminNotificationDeliveries",
    summary: "List paginated in-app notification deliveries",
    parameters: [
      page: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1},
        required: false
      ],
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 100},
        required: false
      ]
    ],
    responses: [ok: {"Deliveries", "application/json", DeliveryListResponse}]
  )

  def index(conn, params) do
    respond(conn, DirectAdminNotifications.list_deliveries(user_id(conn), params))
  end

  operation(:search,
    operation_id: "direct.searchAdminNotificationTargets",
    summary: "Search users to notify",
    parameters: [
      q: [
        in: :query,
        schema: %Schema{type: :string, minLength: 2, maxLength: 120},
        required: true
      ]
    ],
    responses: [ok: {"Targets", "application/json", TargetListResponse}]
  )

  def search(conn, params) do
    respond(
      conn,
      DirectAdminNotifications.search_targets(user_id(conn), params["q"]),
      fn targets ->
        %{targets: targets}
      end
    )
  end

  operation(:create,
    operation_id: "direct.sendAdminNotification",
    summary: "Create an in-app notification and queue optional SMS or WhatsApp via Oban",
    request_body: {"Send notification", "application/json", SendRequest},
    responses: [ok: {"Sent", "application/json", SendResponse}]
  )

  def create(conn, params) do
    respond(conn, DirectAdminNotifications.send(user_id(conn), params))
  end

  operation(:preview_broadcast,
    operation_id: "direct.previewAdminNotificationBroadcast",
    summary: "Preview a role-segment broadcast audience",
    parameters: [
      segment: [
        in: :query,
        schema: %Schema{type: :string, enum: ["customers", "cleaners", "all_app_users"]},
        required: true
      ]
    ],
    responses: [ok: {"Audience preview", "application/json", BroadcastPreviewResponse}]
  )

  def preview_broadcast(conn, params) do
    respond(conn, DirectAdminNotifications.preview_broadcast(user_id(conn), params))
  end

  operation(:broadcast,
    operation_id: "direct.sendAdminNotificationBroadcast",
    summary: "Queue a capped broadcast to a role segment. SMS and WhatsApp send via Oban.",
    request_body: {"Broadcast notification", "application/json", BroadcastRequest},
    responses: [ok: {"Broadcast result", "application/json", BroadcastResponse}]
  )

  def broadcast(conn, params) do
    respond(conn, DirectAdminNotifications.send_broadcast(user_id(conn), params))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, result, mapper \\ & &1)

  defp respond(conn, {:ok, value}, mapper) do
    json(conn, mapper.(value))
  end

  defp respond(conn, {:error, reason}, _mapper) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
