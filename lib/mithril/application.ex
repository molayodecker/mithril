defmodule Mithril.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Mithril.Repo,
      {Phoenix.PubSub, name: Mithril.PubSub},
      MithrilWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mithril.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MithrilWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
