defmodule Mithril.ScheduledJobs.MessageDeliveryFallback do
  @moduledoc false

  require Logger

  alias Mithril.Notifications.SendNotification
  alias Mithril.Repo

  @batch_limit 50
  @in_flight ~w(queued accepted sending sent)

  @spec run() :: :ok | {:error, term()}
  def run do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.query(
           """
           SELECT id, user_id, booking_id, message_type, template_key, to_phone, template_variables
           FROM public.message_delivery_attempts
           WHERE channel = 'sms'
             AND fallback_sent_at IS NULL
             AND (fallback_checked_at IS NULL OR fallback_checked_at < now() - interval '15 minutes')
             AND fallback_after IS NOT NULL
             AND fallback_after <= $1::timestamptz
             AND status = ANY($2::text[])
           ORDER BY fallback_after ASC
           LIMIT $3
           """,
           [now, @in_flight, @batch_limit]
         ) do
      {:ok, %{rows: rows}} ->
        stats =
          Enum.reduce(rows, %{scanned: 0, sent: 0, skipped: 0, failed: 0}, fn row, acc ->
            acc = %{acc | scanned: acc.scanned + 1}
            process_row(row, acc)
          end)

        Logger.info("message_delivery_fallback #{inspect(stats)}")
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp process_row(row, stats) do
    attempt_id = Enum.at(row, 0)

    case claim_fallback(attempt_id) do
      :claimed ->
        case maybe_send_whatsapp(row) do
          :sent ->
            mark_fallback_sent(attempt_id)
            %{stats | sent: stats.sent + 1}

          :skipped ->
            finalize_skipped(attempt_id)
            %{stats | skipped: stats.skipped + 1}

          :failed ->
            release_claim(attempt_id)
            %{stats | failed: stats.failed + 1}
        end

      :not_claimed ->
        %{stats | skipped: stats.skipped + 1}
    end
  end

  defp claim_fallback(attempt_id) do
    case Repo.query(
           """
           UPDATE public.message_delivery_attempts
           SET fallback_checked_at = now()
           WHERE id = $1::uuid
             AND fallback_sent_at IS NULL
             AND (fallback_checked_at IS NULL OR fallback_checked_at < now() - interval '15 minutes')
           RETURNING id
           """,
           [attempt_id]
         ) do
      {:ok, %{num_rows: 1}} -> :claimed
      _ -> :not_claimed
    end
  end

  defp release_claim(attempt_id) do
    Repo.query(
      "UPDATE public.message_delivery_attempts SET fallback_checked_at = NULL WHERE id = $1::uuid",
      [attempt_id]
    )
  end

  defp finalize_skipped(attempt_id) do
    Repo.query(
      """
      UPDATE public.message_delivery_attempts
      SET fallback_checked_at = now(), fallback_after = NULL
      WHERE id = $1::uuid
      """,
      [attempt_id]
    )
  end

  defp mark_fallback_sent(attempt_id) do
    Repo.query(
      """
      UPDATE public.message_delivery_attempts
      SET fallback_sent_at = now(), fallback_after = NULL
      WHERE id = $1::uuid
      """,
      [attempt_id]
    )
  end

  defp maybe_send_whatsapp(row) do
    phone = Enum.at(row, 5)

    cond do
      phone in [nil, ""] ->
        :skipped

      blocked_recipient?(phone) ->
        :skipped

      true ->
        # Full template + OTP decryption lives in the edge shared module; native
        # WhatsApp fallback for booking reminders uses Notifications.Outbound when configured.
        variables =
          case Enum.at(row, 6) do
            map when is_map(map) ->
              map

            json when is_binary(json) ->
              case Jason.decode(json) do
                {:ok, decoded} when is_map(decoded) -> decoded
                _ -> %{}
              end

            _ ->
              %{}
          end

        case SendNotification.invoke_mobile(%{
               "channel" => "whatsapp",
               "phone" => phone,
               "template" => Enum.at(row, 4) || "booking_reminder",
               "variables" => variables
             }) do
          {:ok, response} when is_map(response) ->
            if response["whatsappSent"] == true or response[:whatsappSent] == true,
              do: :sent,
              else: :failed

          _ ->
            :failed
        end
    end
  end

  defp blocked_recipient?(phone) do
    normalized = String.trim(to_string(phone))

    Enum.any?(blocked_recipients(), fn blocked ->
      String.replace(normalized, " ", "") == blocked
    end)
  end

  defp blocked_recipients do
    [
      "+233535729691",
      "+233553754993",
      "+13019791778"
    ]
  end
end
