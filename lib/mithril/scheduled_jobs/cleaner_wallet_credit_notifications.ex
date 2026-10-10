defmodule Mithril.ScheduledJobs.CleanerWalletCreditNotifications do
  @moduledoc false

  @spec run() :: :ok | {:error, term()}
  def run, do: Mithril.WalletCreditNotifications.run()
end
