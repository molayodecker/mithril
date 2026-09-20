defmodule Mithril.PromExTest do
  use ExUnit.Case, async: true

  test "collects the core Mithril operational telemetry" do
    plugin_modules =
      Mithril.PromEx.plugins()
      |> Enum.map(fn
        {module, _opts} -> module
        module -> module
      end)

    assert PromEx.Plugins.Application in plugin_modules
    assert PromEx.Plugins.Beam in plugin_modules
    assert PromEx.Plugins.Phoenix in plugin_modules
    assert PromEx.Plugins.Ecto in plugin_modules
    assert PromEx.Plugins.Oban in plugin_modules
  end

  test "ships PromEx dashboard definitions for the same core systems" do
    dashboards = Mithril.PromEx.dashboards()

    assert {:prom_ex, "application.json"} in dashboards
    assert {:prom_ex, "beam.json"} in dashboards
    assert {:prom_ex, "phoenix.json"} in dashboards
    assert {:prom_ex, "ecto.json"} in dashboards
    assert {:prom_ex, "oban.json"} in dashboards
  end

  test "metrics plug answers /metrics and 404s other paths" do
    opts = Mithril.MetricsPlug.init(prom_ex_module: Mithril.PromEx, path: "/metrics")

    metrics_conn = Plug.Test.conn(:get, "/metrics") |> Mithril.MetricsPlug.call(opts)
    assert metrics_conn.halted
    assert metrics_conn.status in [200, 503]

    other_conn = Plug.Test.conn(:get, "/health") |> Mithril.MetricsPlug.call(opts)
    assert other_conn.status == 404
  end
end
