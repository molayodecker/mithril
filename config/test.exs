import Config

config :mithril, Mithril.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "mithril_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :mithril, MithrilWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-only-secret-key-base-mithril-000000000000000000000000000000000000000000000000",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
