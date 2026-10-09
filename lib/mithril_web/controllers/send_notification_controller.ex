defmodule MithrilWeb.SendNotificationController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Notifications.Outbound

  def create(conn, params) do
    if authorized?(conn) do
      result = Outbound.deliver(params)
      recipient_requested? =
        Enum.any?(["email", "phone"], fn key ->
          is_binary(params[key]) and String.trim(params[key]) != ""
        end)

      delivered? = Enum.any?(["emailSent", "smsSent", "whatsappSent"], &result[&1])

      if recipient_requested? and not delivered? do
        conn
        |> put_status(:bad_gateway)
        |> json(Map.put(result, "error", "Notification delivery failed"))
      else
        json(conn, result)
      end
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    end
  end

  defp authorized?(conn) do
    expected =
      Application.get_env(:mithril, :send_notification_token) |> to_string() |> String.trim()

    token = bearer(conn)

    expected != "" and byte_size(token) == byte_size(expected) and
      Plug.Crypto.secure_compare(token, expected)
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> ""
    end
  end
end
