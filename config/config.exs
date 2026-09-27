import Config

config :mithril,
  ecto_repos: [Mithril.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  database_backend: "supabase",
  transport_router: Mithril.Transport.Router.LocationIQ,
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
  metrics_server: :disabled

config :mithril, :metrics_server,
  port: 9091,
  path: "/metrics"

config :mithril, Oban,
  repo: Mithril.Repo,
  notifier: Oban.Notifiers.Postgres,
  peer: Oban.Peers.Database,
  queues: [notifications: 10, cron: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 14},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    {Oban.Plugins.Cron,
     timezone: "Etc/UTC",
     crontab: [
       {"0 * * * *", Mithril.Workers.BookingReminderSweep},
       {"*/15 * * * *", Mithril.Workers.DatabaseCron,
        args: %{name: "auth_lookup_rate_limit_prune"}},
       {"0 * * * *", Mithril.Workers.DatabaseCron, args: %{name: "auto-close-stale-bookings"}},
       {"*/10 * * * *", Mithril.Workers.DatabaseCron,
        args: %{name: "broadcast-unassigned-paid-bookings"}},
       {"*/15 * * * *", Mithril.Workers.DatabaseCron,
        args: %{name: "cleanup-expired-welcome-promo-reservations"}},
       {"*/5 * * * *", Mithril.Workers.DatabaseCron,
        args: %{name: "escalate-unassigned-paid-bookings-past-grace"}},
       {"0 * * * *", Mithril.Workers.DatabaseCron,
        args: %{name: "expire_stale_pending_bookings_job"}},
       {"*/5 * * * *", Mithril.Workers.DatabaseCron,
        args: %{name: "process-direct-assignment-holds"}},
       {"15 5 * * *", Mithril.Workers.DatabaseCron,
        args: %{name: "refresh_cleaner_health_snapshots"}},
       {"*/5 * * * *", Mithril.Workers.DatabaseCron, args: %{name: "release_cleaner_hold_15min"}}
     ]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
