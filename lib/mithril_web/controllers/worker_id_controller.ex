defmodule MithrilWeb.WorkerIdController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.WorkerId
  alias Mithril.WorkerIdPass

  def show(conn, %{"code" => code}) do
    case WorkerId.public_card(code) do
      {:ok, card} ->
        json(conn, card)

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :unavailable} ->
        conn |> put_status(503) |> json(%{error: "worker_id_unavailable"})
    end
  end

  def download(conn, %{"code" => code} = params) do
    case WorkerIdPass.pkpass_for_download(code, params["token"] || "") do
      {:ok, binary} ->
        conn
        |> put_resp_content_type("application/vnd.apple.pkpass")
        |> put_resp_header("content-disposition", "attachment; filename=\"worker-id.pkpass\"")
        |> send_resp(200, binary)

      {:error, :wallet_not_configured} ->
        conn |> put_status(503) |> json(%{error: "wallet_not_configured"})

      {:error, :unavailable} ->
        conn |> put_status(503) |> json(%{error: "worker_id_unavailable"})

      {:error, :not_found} ->
        send_resp(conn, 404, "")
    end
  end

  def sync(conn, params) do
    header = conn |> get_req_header("authorization") |> List.first()

    if WorkerIdPass.authorized_sync?(header) do
      case WorkerIdPass.sync_user(params["userId"] || params["user_id"]) do
        :ok ->
          json(conn, %{ok: true})

        {:error, :invalid_user} ->
          conn |> put_status(400) |> json(%{error: "invalid_user"})

        {:error, :unavailable} ->
          conn |> put_status(503) |> json(%{error: "worker_id_unavailable"})
      end
    else
      conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end
end
