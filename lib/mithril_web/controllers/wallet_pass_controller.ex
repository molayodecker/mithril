defmodule MithrilWeb.WalletPassController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.WorkerIdPass

  def register(conn, params) do
    push_token = push_token(conn)

    case WorkerIdPass.register(
           params["device_library_id"],
           params["pass_type_id"],
           params["serial"],
           apple_token(conn),
           push_token
         ) do
      :ok ->
        send_resp(conn, 201, "")

      {:error, :unauthorized} ->
        send_resp(conn, 401, "")

      {:error, :unavailable} ->
        send_resp(conn, 503, "")
    end
  end

  def unregister(conn, params) do
    case WorkerIdPass.unregister(
           params["device_library_id"],
           params["pass_type_id"],
           params["serial"],
           apple_token(conn)
         ) do
      :ok -> send_resp(conn, 200, "")
      {:error, :unauthorized} -> send_resp(conn, 401, "")
    end
  end

  def serials(conn, params) do
    case WorkerIdPass.serials(
           params["device_library_id"],
           params["pass_type_id"],
           params["passesUpdatedSince"]
         ) do
      {:ok, body} -> json(conn, body)
      :none -> send_resp(conn, 204, "")
      {:error, :unavailable} -> send_resp(conn, 503, "")
    end
  end

  def show(conn, params) do
    case WorkerIdPass.pkpass_for_serial(params["serial"], apple_token(conn)) do
      {:ok, binary} ->
        conn
        |> put_resp_content_type("application/vnd.apple.pkpass")
        |> send_resp(200, binary)

      {:error, :unauthorized} ->
        send_resp(conn, 401, "")

      {:error, :not_found} ->
        send_resp(conn, 404, "")

      {:error, :wallet_not_configured} ->
        send_resp(conn, 503, "")

      {:error, :unavailable} ->
        send_resp(conn, 503, "")
    end
  end

  def log(conn, _params) do
    send_resp(conn, 200, "")
  end

  defp apple_token(conn) do
    case get_req_header(conn, "authorization") do
      ["ApplePass " <> token] -> String.trim(token)
      _ -> ""
    end
  end

  defp push_token(conn) do
    case conn.body_params do
      %{"pushToken" => token} when is_binary(token) -> String.trim(token)
      _ -> ""
    end
  end
end
