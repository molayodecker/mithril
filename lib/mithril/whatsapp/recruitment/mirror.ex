defmodule Mithril.WhatsApp.Recruitment.Mirror do
  @moduledoc false

  require Logger

  def maybe_sync(lead_id) when is_binary(lead_id) and lead_id != "" do
    secret = Application.get_env(:mithril, :recruitment_lead_application_sync_secret)
    base = Application.get_env(:mithril, :app_url)

    if present?(secret) and present?(base) do
      Task.start(fn ->
        sync_lead(lead_id, String.trim(secret), String.trim_trailing(base, "/"))
      end)
    else
      Logger.warning(
        "whatsapp recruitment skipping cleaner_applications sync: missing secret or APP_URL"
      )
    end

    :ok
  end

  def maybe_sync(_), do: :ok

  defp sync_lead(lead_id, secret, base) do
    url = "#{base}/api/recruitment/sync-lead-application"

    case Req.post(url,
           json: %{lead_id: lead_id},
           headers: [{"x-recruitment-sync-secret", secret}],
           receive_timeout: 8_000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.error(
          "whatsapp recruitment cleaner_applications sync failed status=#{status} lead=#{lead_id}"
        )

      {:error, error} ->
        Logger.error(
          "whatsapp recruitment cleaner_applications sync failed #{inspect(error)} lead=#{lead_id}"
        )
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
