defmodule MithrilWeb.WhatsAppRecruitmentController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html, :json, :xml]

  alias Mithril.WhatsApp.Recruitment
  alias Mithril.WhatsApp.Recruitment.GhanaCard

  def serve(%Plug.Conn{method: "OPTIONS"} = conn, %{"upload" => "ghana"}) do
    conn
    |> cors()
    |> send_resp(204, "")
  end

  def serve(%Plug.Conn{method: "GET"} = conn, %{"upload" => "ghana"} = params) do
    conn = cors(conn)

    case Recruitment.handle_ghana_get(params["t"]) do
      {:redirect, url} ->
        redirect(conn, external: url)

      {:error, :missing_token} ->
        send_resp(conn, 400, "Missing token")

      {:error, :unauthorized} ->
        send_resp(conn, 401, "Invalid or expired link")
    end
  end

  def serve(%Plug.Conn{method: "POST"} = conn, %{"upload" => "ghana"} = params) do
    conn
    |> cors()
    |> ghana_post(params)
  end

  def serve(%Plug.Conn{method: "POST"} = conn, _params) do
    signature = conn |> get_req_header("x-twilio-signature") |> List.first()

    case Recruitment.handle_webhook(conn.body_params, signature) do
      {:ok, xml} ->
        conn
        |> put_resp_content_type("text/xml")
        |> send_resp(200, xml)

      {:error, :unauthorized} ->
        send_resp(conn, 401, "Unauthorized")

      {:error, :not_configured} ->
        send_resp(conn, 503, "Not configured")
    end
  end

  def serve(conn, _params) do
    send_resp(conn, 405, "Method not allowed")
  end

  defp ghana_post(conn, params) do
    case Recruitment.handle_ghana_post(params) do
      {:redirect, url} ->
        redirect(conn, external: url)

      {:html_error, status, title, message} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(status, GhanaCard.html_error(title, message))
    end
  end

  defp cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Content-Type")
  end
end
