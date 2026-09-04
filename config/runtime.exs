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
socket_options = if truthy_env?.("ECTO_IPV6"), do: [:inet6], else: []

# Tests must use config/test.exs (local mithril_test). A shell/direnv
# DATABASE_URL often points at production and would make mix test mutate it.
if config_env() != :test do
  if database_url = System.get_env("DATABASE_URL") do
    config :mithril, Mithril.Repo,
      url: database_url,
      pool_size: pool_size,
      socket_options: socket_options
  end
end

if parity_token = System.get_env("MITHRIL_PARITY_TOKEN") do
  config :mithril, :parity_token, parity_token
end

if direct_gateway_token = System.get_env("MITHRIL_DIRECT_TOKEN") do
  config :mithril, :direct_gateway_token, direct_gateway_token
end

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  host = System.fetch_env!("PHX_HOST")
  port = parse_positive_integer.("PORT", "4000")

  config :mithril, Mithril.Repo,
    url: database_url,
    pool_size: pool_size,
    socket_options: socket_options

  config :mithril, MithrilWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
