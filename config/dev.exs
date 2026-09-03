import Config

config :mithril, Mithril.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "mithril_dev",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true,
  pool_size: 10

config :mithril, MithrilWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev-only-secret-key-base-mithril-change-me-before-any-shared-environment-000000000000000000000000",
  watchers: []

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
