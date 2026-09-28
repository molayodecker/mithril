defmodule Mithril.ScheduledJobs.SyncPropertyCalendarFeeds do
  @moduledoc false

  alias Mithril.PropertyCalendarSync

  @spec run() :: :ok | {:error, term()}
  def run, do: PropertyCalendarSync.sync_batch()
end
