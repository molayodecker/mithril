defmodule Mithril.ScheduledJobs.AdminBroadcastWorker do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.Workers.AdminBroadcastBatch

  @spec run() :: :ok | {:error, term()}
  def run do
    case Repo.query("""
         SELECT id FROM public.admin_broadcasts
         WHERE delivery_mode = 'worker' AND status IN ('queued', 'sending')
         ORDER BY created_at ASC
         LIMIT 1
         """) do
      {:ok, %{rows: [[broadcast_id]]}} ->
        _ = AdminBroadcastBatch.enqueue(broadcast_id)
        :ok

      {:ok, %{rows: []}} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end
end
