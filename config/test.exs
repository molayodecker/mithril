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

config :mithril, Mithril.PromEx,
  disabled: true,
  metrics_server: :disabled

config :mithril, :metrics_server, :disabled

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

config :bcrypt_elixir, log_rounds: 4

config :mithril,
  auth_jwt_secret: "test-only-mithril-jwt-secret-000000000000000000000000",
  auth_access_ttl: 3600,
  auth_refresh_ttl: 86_400,
  sms_adapter: Mithril.Auth.SMS.Test,
  paystack_adapter: Mithril.Paystack.Test,
  paystack_secret_key: "sk_test_webhook_secret",
  start_oban: false,
  google_client_ids: ["test-google-client"],
  facebook_app_id: "test-facebook-app",
  facebook_app_secret: "test-facebook-secret",
  transport_router: Mithril.Transport.Router.Stub,
  app_url: "https://tryinstaclean.com",
  twilio_account_sid: "ACtestrecruitment",
  twilio_auth_token: "test-twilio-auth-token",
  twilio_webhook_url: "https://api.tryinstaclean.com/whatsapp/join-as-cleaner-bot",
  twilio_webhook_url_alias: "https://api.tryinstaclean.com/functions/v1/join-as-cleaner-bot",
  sumsub_webhook_secret: "test-sumsub-webhook-secret",
  recruitment_upload_secret: "test-recruitment-upload-secret",
  whatsapp_recruitment_store: Mithril.WhatsApp.Recruitment.Leads.Memory,
  twilio_http: :noop
