defmodule Mithril.Workers.ContractWorkerRatingSweep do
  @moduledoc """
  Sends due contract worker-rating WhatsApp messages at 06:15 Accra.
  """

  use Oban.Worker, queue: :cron, max_attempts: 3, unique: [period: 3600]

  alias Mithril.DirectContracts.WorkerRating

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    WorkerRating.send_due()
  end
end
