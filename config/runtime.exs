import Config

# Phoenix 1.8 starts Bandit only when the endpoint has server: true.
# MIX_ENV=test compiles with server: false, so CI must set PHX_SERVER=true
# here — before the application boots — rather than relying on mix phx.server.
if System.get_env("PHX_SERVER") do
  config :mithril, MithrilWeb.Endpoint, server: true
end

parse_positive_integer = fn name, default ->
  value = System.get_env(name) || default

  case Integer.parse(value) do
    {integer, ""} when integer > 0 ->
      integer

    _ ->
      raise "#{name} must be a positive integer, got: #{inspect(value)}"
  end
end

truthy_env? = fn name ->
  System.get_env(name) in ~w(1 true TRUE yes YES)
end

pool_size = parse_positive_integer.("POOL_SIZE", "10")

repo_opts = fn database_url ->
  socket_options =
    cond do
      String.contains?(database_url, "flympg.net") or
        String.contains?(database_url, ".flycast") or
          String.contains?(database_url, ".internal") ->
        [:inet6]

      truthy_env?.("ECTO_IPV6") ->
        [:inet6]

      true ->
        []
    end

  opts = [
    url: database_url,
    pool_size: pool_size,
    socket_options: socket_options
  ]

  opts =
    if String.contains?(database_url, "pgbouncer") or String.contains?(database_url, ":6432") do
      Keyword.put(opts, :prepare, :unnamed)
    else
      opts
    end

  cond do
    truthy_env?.("FLY_DATABASE_SSL_DISABLE") ->
      opts

    String.contains?(database_url, "flympg.net") ->
      Keyword.put(opts, :ssl, true)

    true ->
      opts
  end
end

# Tests must use config/test.exs (local mithril_test). A shell/direnv
# DATABASE_URL often points at production and would make mix test mutate it.
if config_env() != :test do
  {database_backend, database_url} = Mithril.DatabaseBackend.resolve()

  config :mithril, :database_backend, database_backend

  if database_url do
    config :mithril, Mithril.Repo, repo_opts.(database_url)
  end
end

config :mithril, :direct_client_bookings, truthy_env?.("DIRECT_CLIENT_BOOKINGS")

if parity_token = System.get_env("MITHRIL_PARITY_TOKEN") do
  config :mithril, :parity_token, parity_token
end

if direct_gateway_token = System.get_env("MITHRIL_DIRECT_TOKEN") do
  config :mithril, :direct_gateway_token, direct_gateway_token
end

if jwt_secret = System.get_env("AUTH_JWT_SECRET") do
  config :mithril, :auth_jwt_secret, jwt_secret
end

if System.get_env("AUTH_ACCESS_TTL") do
  config :mithril, :auth_access_ttl, parse_positive_integer.("AUTH_ACCESS_TTL", "3600")
end

if System.get_env("AUTH_REFRESH_TTL") do
  config :mithril, :auth_refresh_ttl, parse_positive_integer.("AUTH_REFRESH_TTL", "2592000")
end

if google_client_ids = System.get_env("GOOGLE_CLIENT_IDS") do
  config :mithril, :google_client_ids, google_client_ids
end

if facebook_app_id = System.get_env("FACEBOOK_APP_ID") do
  config :mithril, :facebook_app_id, facebook_app_id
end

if facebook_app_secret = System.get_env("FACEBOOK_APP_SECRET") do
  config :mithril, :facebook_app_secret, facebook_app_secret
end

if twilio_sid = System.get_env("TWILIO_ACCOUNT_SID") do
  config :mithril, :twilio_account_sid, twilio_sid
end

if twilio_token = System.get_env("TWILIO_AUTH_TOKEN") do
  config :mithril, :twilio_auth_token, twilio_token
end

if twilio_from = System.get_env("TWILIO_PHONE_NUMBER") || System.get_env("TWILIO_FROM_NUMBER") do
  config :mithril, :twilio_from_number, twilio_from
end

if messaging_service = System.get_env("TWILIO_MESSAGING_SERVICE_SID") do
  config :mithril, :twilio_messaging_service_sid, messaging_service
end

if System.get_env("TWILIO_ACCOUNT_SID") && System.get_env("TWILIO_AUTH_TOKEN") &&
     (System.get_env("TWILIO_MESSAGING_SERVICE_SID") || System.get_env("TWILIO_PHONE_NUMBER") ||
        System.get_env("TWILIO_FROM_NUMBER")) do
  config :mithril, :sms_adapter, Mithril.Auth.SMS.Twilio
end

if test_phones = System.get_env("AUTH_TEST_PHONES") do
  config :mithril, :sms_test_phones, Mithril.Auth.TestPhones.parse(test_phones)
end

if paystack_secret = System.get_env("PAYSTACK_SECRET_KEY") do
  config :mithril, :paystack_secret_key, paystack_secret
  config :mithril, :paystack_adapter, Mithril.Paystack.HTTP
end

if sumsub_webhook_secret = System.get_env("SUMSUB_WEBHOOK_SECRET") do
  config :mithril, :sumsub_webhook_secret, sumsub_webhook_secret
end

if sumsub_level_name =
     System.get_env("SUMSUB_LEVEL_NAME") || System.get_env("SUMSUB_WORKER_LEVEL_NAME") do
  config :mithril, :sumsub_level_name, sumsub_level_name
end

if tax_subaccount = System.get_env("PAYSTACK_TAX_SUBACCOUNT") do
  config :mithril, :paystack_tax_subaccount, tax_subaccount
end

if vendor_subaccount = System.get_env("PAYSTACK_VENDOR_SUBACCOUNT") do
  config :mithril, :paystack_vendor_subaccount, vendor_subaccount
end

if send_notification_url = System.get_env("SEND_NOTIFICATION_URL") do
  config :mithril, :send_notification_url, send_notification_url
end

if send_notification_token = System.get_env("SEND_NOTIFICATION_TOKEN") do
  config :mithril, :send_notification_token, send_notification_token
end

if direct_public_url = System.get_env("DIRECT_PUBLIC_URL") do
  config :mithril, :direct_public_url, direct_public_url
end

if app_url = System.get_env("APP_URL") do
  config :mithril, :app_url, String.trim_trailing(app_url, "/")
end

if twilio_webhook_url = System.get_env("TWILIO_WEBHOOK_URL") do
  config :mithril, :twilio_webhook_url, twilio_webhook_url
end

if twilio_webhook_alias = System.get_env("TWILIO_WEBHOOK_URL_ALIAS") do
  config :mithril, :twilio_webhook_url_alias, twilio_webhook_alias
end

if recruitment_upload_secret = System.get_env("RECRUITMENT_UPLOAD_SECRET") do
  config :mithril, :recruitment_upload_secret, recruitment_upload_secret
end

if recruitment_sync_secret = System.get_env("RECRUITMENT_LEAD_APPLICATION_SYNC_SECRET") do
  config :mithril, :recruitment_lead_application_sync_secret, recruitment_sync_secret
end

if supabase_url = System.get_env("SUPABASE_URL") do
  config :mithril, :supabase_url, String.trim_trailing(supabase_url, "/")
end

if supabase_service_role_key = System.get_env("SUPABASE_SERVICE_ROLE_KEY") do
  config :mithril, :supabase_service_role_key, supabase_service_role_key
end

# Deleted: GHANA_CARD_RECRUITMENT_BUCKET / :ghana_card_recruitment_bucket.
# Recruitment storage uses the hardcoded cleaner-ghana-card-id bucket.

if admin_from = System.get_env("TWILIO_WHATSAPP_ADMIN_FROM") do
  config :mithril, :twilio_whatsapp_admin_from, admin_from
end

if welcome_sid = System.get_env("TWILIO_WHATSAPP_WELCOME_CONTENT_SID") do
  config :mithril, :twilio_whatsapp_welcome_content_sid, welcome_sid
end

if yes_no_sid = System.get_env("TWILIO_WHATSAPP_YES_NO_CONTENT_SID") do
  config :mithril, :twilio_whatsapp_yes_no_content_sid, yes_no_sid
end

if accept_sid = System.get_env("TWILIO_WHATSAPP_ACCEPT_CONTENT_SID") do
  config :mithril, :twilio_whatsapp_accept_content_sid, accept_sid
end

if submit_sid = System.get_env("TWILIO_WHATSAPP_SUBMIT_CONTENT_SID") do
  config :mithril, :twilio_whatsapp_submit_content_sid, submit_sid
end

if equipment_sid = System.get_env("TWILIO_WHATSAPP_EQUIPMENT_CONTENT_SID") do
  config :mithril, :twilio_whatsapp_equipment_content_sid, equipment_sid
end

if config_env() != :prod and truthy_env?.("DISABLE_TWILIO_SIGNATURE_VALIDATION") do
  config :mithril, :disable_twilio_signature_validation, true
end

if config_env() == :prod do
  {database_backend, database_url} = Mithril.DatabaseBackend.resolve!()
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  host = System.fetch_env!("PHX_HOST")
  port = parse_positive_integer.("PORT", "4000")

  config :mithril, :database_backend, database_backend

  config :mithril, Mithril.Repo, repo_opts.(database_url)

  config :mithril, MithrilWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
