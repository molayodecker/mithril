defmodule Mithril.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [Mithril.PromEx] ++
        metrics_server_child() ++
        [
          Mithril.Repo,
          {Phoenix.PubSub, name: Mithril.PubSub},
          MithrilWeb.Endpoint
        ] ++ oban_child() ++ recruitment_store_child()

    Supervisor.start_link(children, strategy: :one_for_one, name: Mithril.Supervisor)
  end

  defp metrics_server_child do
    case Application.get_env(:mithril, :metrics_server, :disabled) do
      :disabled ->
        []

      opts when is_list(opts) ->
        port = Keyword.fetch!(opts, :port)
        path = Keyword.get(opts, :path, "/metrics")

        [
          Supervisor.child_spec(
            {Bandit,
             [
               plug: {PromEx.Plug, [prom_ex_module: Mithril.PromEx, path: path]},
               scheme: :http,
               port: port,
               ip: :any,
               startup_log: false
             ]},
            id: Mithril.MetricsServer
          )
        ]
    end
  end

  defp oban_child do
    if Application.get_env(:mithril, :start_oban, true) do
      [{Oban, Application.fetch_env!(:mithril, Oban)}]
    else
      []
    end
  end

  defp recruitment_store_child do
    case Application.get_env(:mithril, :whatsapp_recruitment_store) do
      Mithril.WhatsApp.Recruitment.Leads.Memory ->
        [
          %{
            id: Mithril.WhatsApp.Recruitment.Leads.Memory,
            start: {Mithril.WhatsApp.Recruitment.Leads.Memory, :start_link, []}
          }
        ]

      _ ->
        []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    MithrilWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
