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
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:bcrypt_elixir, "~> 3.3"}
    ]
  end
end
