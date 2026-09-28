defmodule Mithril.ScheduledJobs.CleanupExpiredCleaningScanMedia do
  @moduledoc false

  require Logger

  alias Mithril.Repo
  alias Mithril.StorageCleanup.CleaningScanMedia

  @spec run() :: :ok | {:error, term()}
  def run do
    case CleaningScanMedia.interpret_rpc_result(
           Repo.query("SELECT public.cleanup_expired_cleaning_scan_media()")
         ) do
      :ok ->
        :ok

      :skipped ->
        Logger.warning("cleanup_expired_cleaning_scan_media RPC missing; skipping")
        :ok

      {:error, error} ->
        {:error, error}
    end
  end
end
