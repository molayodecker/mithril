defmodule Mithril.Workers.AdminBroadcastBatch do
  @moduledoc false

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [fields: [:worker, :args], keys: [:broadcast_id]]

  alias Mithril.AdminBroadcast.{Delivery, Progress}
  alias Mithril.Repo

  @batch_size Delivery.batch_size()

  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(broadcast_id) when is_binary(broadcast_id) do
    %{broadcast_id: broadcast_id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"broadcast_id" => broadcast_id}}) do
    case load_broadcast(broadcast_id) do
      {:ok, broadcast} ->
        deliver_batch(broadcast)

      {:error, :not_found} ->
        :discard

      {:error, error} ->
        {:error, error}
    end
  end

  def perform(_job), do: :discard

  defp deliver_batch(broadcast) do
    recipient_ids = Delivery.parse_recipient_ids(broadcast["recipient_user_ids"])

    if recipient_ids == [] do
      mark_failed(broadcast["id"], "Empty recipient snapshot.")
      :ok
    else
      maybe_claim_sending(broadcast)

      offset = broadcast["process_offset"] || 0
      {batch_ids, _new_offset, done?} = Progress.next_batch(recipient_ids, offset, @batch_size)

      cond do
        batch_ids == [] and done? ->
          finalize_broadcast(broadcast)
          :ok

        batch_ids == [] ->
          finalize_broadcast(broadcast)
          :ok

        true ->
          case Delivery.deliver_batch(broadcast, batch_ids) do
            {:ok, batch_stats} ->
              merge_and_continue(broadcast, recipient_ids, offset, batch_stats)

            {:error, error} ->
              {:error, error}
          end
      end
    end
  end

  defp maybe_claim_sending(%{"status" => "queued"} = broadcast) do
    Repo.query(
      """
      UPDATE public.admin_broadcasts
      SET status = 'sending', started_at = now()
      WHERE id = $1::uuid AND status = 'queued'
      """,
      [broadcast["id"]]
    )
  end

  defp maybe_claim_sending(_broadcast), do: :ok

  defp merge_and_continue(broadcast, recipient_ids, offset, batch_stats) do
    {merged, new_offset, done, final_status} =
      Progress.merge_progress(
        broadcast["stats"],
        batch_stats,
        offset,
        recipient_ids,
        @batch_size
      )

    case Repo.query(
           """
           UPDATE public.admin_broadcasts
           SET process_offset = $2,
               stats = $3::jsonb,
               skipped_prefs_count = skipped_prefs_count + $4,
               eligible_count = eligible_count + $5,
               status = CASE WHEN $6 THEN $7 ELSE status END,
               error_message = CASE WHEN $6 AND $8 THEN 'No deliveries succeeded.' ELSE error_message END,
               completed_at = CASE WHEN $6 THEN now() ELSE completed_at END
           WHERE id = $1::uuid AND process_offset = $9
           """,
           [
             broadcast["id"],
             new_offset,
             Jason.encode!(merged),
             batch_stats["skippedPrefs"],
             batch_stats["attempted"],
             done,
             final_status || broadcast["status"],
             final_status == "failed",
             offset
           ]
         ) do
      {:ok, %{num_rows: 1}} ->
        if done do
          :ok
        else
          case enqueue(broadcast["id"]) do
            {:ok, _job} -> :ok
            {:error, error} -> {:error, error}
          end
        end

      {:ok, %{num_rows: 0}} ->
        {:error, :stale_broadcast_offset}

      {:error, error} ->
        {:error, error}
    end
  end

  defp finalize_broadcast(broadcast) do
    stats = Delivery.parse_stats(broadcast["stats"])

    Repo.query(
      """
      UPDATE public.admin_broadcasts
      SET status = $2, error_message = $3, completed_at = now()
      WHERE id = $1::uuid
      """,
      [
        broadcast["id"],
        if(Delivery.delivered_any?(stats), do: "completed", else: "failed"),
        if(Delivery.delivered_any?(stats), do: nil, else: "No deliveries succeeded.")
      ]
    )
  end

  defp mark_failed(broadcast_id, message) do
    Repo.query(
      """
      UPDATE public.admin_broadcasts
      SET status = 'failed', error_message = $2, completed_at = now()
      WHERE id = $1::uuid
      """,
      [broadcast_id, message]
    )
  end

  defp load_broadcast(broadcast_id) do
    case Repo.query(
           """
           SELECT id, status, delivery_mode, process_offset, recipient_user_ids, stats, channels,
                  requires_marketing_consent, title, message, notification_type, screen,
                  whatsapp_content_sid, skipped_prefs_count, eligible_count
           FROM public.admin_broadcasts WHERE id = $1::uuid LIMIT 1
           """,
           [broadcast_id]
         ) do
      {:ok, %{columns: columns, rows: [row]}} ->
        {:ok, Map.new(Enum.zip(columns, row))}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end
end
