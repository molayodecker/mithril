import Config

config :mithril,
  ecto_repos: [Mithril.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  database_backend: "supabase",
  auth_access_ttl: 3600,
  auth_refresh_ttl: 60 * 60 * 24 * 30,
  direct_client_bookings: false

config :mithril, MithrilWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MithrilWeb.ErrorHTML, json: MithrilWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mithril.PubSub

config :phoenix, :json_library, Jason

config :mithril, Mithril.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [:phoenix_channel_event_metrics, :phoenix_socket_event_metrics],
  grafana: :disabled,
  metrics_server: [
    port: 9091,
    path: "/metrics",
    protocol: :http,
    pool_size: 2,
    auth_strategy: :none
  ]

config :mithril, Oban,
  repo: Mithril.Repo,
  notifier: Oban.Notifiers.Postgres,
  peer: Oban.Peers.Database,
  queues: [notifications: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 14},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    {Oban.Plugins.Cron,
     timezone: "Etc/UTC",
     crontab: [
       {"0 * * * *", Mithril.Workers.BookingReminderSweep}
     ]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
