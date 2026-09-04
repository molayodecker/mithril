import Config

config :mithril, Mithril.Repo,
  username: System.get_env("POSTGRES_USER") || "postgres",
  password: System.get_env("POSTGRES_PASSWORD") || "postgres",
  hostname: System.get_env("POSTGRES_HOST") || "localhost",
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

config :bcrypt_elixir, log_rounds: 4

config :mithril,
  auth_jwt_secret: "test-only-mithril-jwt-secret-000000000000000000000000",
  auth_access_ttl: 3600,
  auth_refresh_ttl: 86_400
