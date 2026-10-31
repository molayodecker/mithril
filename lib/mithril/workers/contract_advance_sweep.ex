defmodule Mithril.Workers.ContractAdvanceSweep do
  @moduledoc """
  Credits automatic weekly advances at 06:00 Accra, which is 06:00 GMT.
  """

  use Oban.Worker, queue: :cron, max_attempts: 3, unique: [period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Mithril.DirectContracts.pay_automatic_advances() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
