defmodule Mithril.Workers.ScheduledJob do
  @moduledoc false

  use Oban.Worker, queue: :cron, max_attempts: 3, unique: [period: 60, keys: [:name]]

  require Logger

  alias Mithril.ScheduledJobs

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"name" => name}}) when is_binary(name) do
    case ScheduledJobs.run(name) do
      :ok ->
        Logger.info("scheduled_job name=#{name} ok")
        :ok

      {:error, :missing_config} ->
        Logger.warning("scheduled_job name=#{name} skipped missing_config")
        :discard

      {:error, reason} ->
        Logger.warning("scheduled_job name=#{name} failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(_job), do: :discard
end
