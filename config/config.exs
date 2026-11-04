import Config

config :mithril,
  ecto_repos: [Mithril.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  database_backend: "supabase",
  outbox_dispatcher: true,
  transport_router: Mithril.Transport.Router.LocationIQ,
  auth_access_ttl: 3600,
  auth_refresh_ttl: 60 * 60 * 24 * 30,
  direct_client_bookings: false,
  stripe_booking_checkout_env_gate: :unset

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
    # Crontab is filled at runtime from `Mithril.Cron.Jobs` (see `config/runtime.exs`).
    {Oban.Plugins.Cron, timezone: "Etc/UTC", crontab: []}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# The DSN, environment, and release come from the runtime environment.
# `logs` without a level attaches crash reporting and leaves Sentry Logs off.
config :sentry,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  source_code_path_pattern: "lib/**/*.ex",
  in_app_otp_apps: [:mithril],
  traces_sample_rate: 1.0,
  traces_sampler: {Mithril.Sentry, :traces_sampler},
  before_send: {Mithril.Sentry, :before_send},
  logs: [capture_metadata: [:request_id]],
  integrations: [
    oban: [
      capture_errors: true,
      should_report_error_callback: &Mithril.Sentry.report_oban_error?/2
    ]
  ],
  scrubber: [
    param_keys: [
      "phone",
      "email",
      "otp",
      "cvv",
      "cvc",
      "card",
      "pan",
      "account_number",
      "iban",
      "ghana_card"
    ]
  ]

# Keep the OpenTelemetry exporter quiet unless a DSN turns on Sentry's processor.
config :opentelemetry, traces_exporter: :none

import_config "#{config_env()}.exs"
