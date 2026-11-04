defmodule Mithril.MixProject do
  use Mix.Project

  def project do
    [
      app: :mithril,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Mithril.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:bcrypt_elixir, "~> 3.3"},
      {:req, "~> 0.5"},
      {:open_api_spex, "~> 3.22.3"},
      {:oban, "~> 2.19"},
      {:prom_ex, "~> 1.12"},
      {:sentry, "~> 14.0"},
      {:finch, "~> 0.21"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:ex_phone_number, "~> 0.4.12"},
      {:ex_email, "~> 1.0"}
    ]
  end
end
