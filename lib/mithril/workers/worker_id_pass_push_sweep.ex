defmodule Mithril.Workers.WorkerIdPassPushSweep do
  @moduledoc """
  Retries durable Wallet pass refresh notifications after worker status changes.
  The database trigger sets push_pending, so notifications survive process crashes.
  """

  use Oban.Worker, queue: :cron, max_attempts: 5

  @impl true
  def perform(%Oban.Job{}) do
    Mithril.WorkerIdPass.flush_pending_pushes()
  end
end
