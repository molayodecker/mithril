defmodule MithrilWeb.SumsubWebhookController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Mithril.Sumsub.Webhook
  alias MithrilWeb.CacheBodyReader

  def create(conn, _params) do
    raw_body = CacheBodyReader.body(conn)
    digest = conn |> get_req_header("x-payload-digest") |> List.first()

    case Webhook.handle(raw_body, digest) do
      {:ok, result} ->
        json(conn, %{
          ok: true,
          requestId: result.request_id,
          applicantId: result.applicant_id,
          externalUserId: result.external_user_id,
          kycStatus: result.kyc_status,
          workerMirrored: result.worker_mirrored,
          workerApplicationKycStatus: result.worker_application_kyc_status,
          workerVerificationStatus: result.worker_verification_status,
          workerApplicationId: encode_uuid(result.worker_application_id),
          skippedStale: result.skipped_stale
        })

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid webhook signature"})

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Missing SUMSUB_WEBHOOK_SECRET"})

      {:error, :invalid_json} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid JSON payload"})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing required fields"})

      {:error, :conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Applicant id belongs to a different user"})

      {:error, :database_unavailable} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to persist Sumsub webhook"})
    end
  end

  defp encode_uuid(nil), do: nil

  defp encode_uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
