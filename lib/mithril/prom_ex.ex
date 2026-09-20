defmodule Mithril.PromEx do
  @moduledoc """
  Prometheus instrumentation for Mithril.

  Fly.io scrapes the standalone metrics server on port 9091. The port is not
  exposed through Mithril's public HTTP service.
  """

  use PromEx, otp_app: :mithril

  @impl true
  def plugins do
    [
      {PromEx.Plugins.Application,
       otp_app: :mithril,
       deps: [:phoenix, :ecto_sql, :postgrex, :oban, :prom_ex]},
      {PromEx.Plugins.Beam, poll_rate: 15_000},
      {PromEx.Plugins.Phoenix,
       endpoint: MithrilWeb.Endpoint,
       router: MithrilWeb.Router},
      {PromEx.Plugins.Ecto, repos: [Mithril.Repo]},
      {PromEx.Plugins.Oban, oban_supervisors: [Oban], poll_rate: 15_000}
    ]
  end

  @impl true
  def dashboards do
    [
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"},
      {:prom_ex, "phoenix.json"},
      {:prom_ex, "ecto.json"},
      {:prom_ex, "oban.json"}
    ]
  end
end
