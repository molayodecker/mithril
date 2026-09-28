defmodule MithrilWeb.SendNotificationController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Notifications.Outbound

  def create(conn, params) do
    if authorized?(conn) do
      json(conn, Outbound.deliver(params))
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
