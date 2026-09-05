import Config

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
      String.contains?(database_url, "flympg.net") -> [:inet6]
      truthy_env?.("ECTO_IPV6") -> [:inet6]
      true -> []
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

  if String.contains?(database_url, "flympg.net") do
    Keyword.put(opts, :ssl, true)
  else
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
