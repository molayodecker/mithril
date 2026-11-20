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

# Local Wallet signing files live in gitignored .env. Mithril does not load
# that file on its own, and these paths must not be committed.
wallet_keys = [
  "APPLE_PASS_CERTIFICATE_PATH",
  "APPLE_PASS_KEY_PATH",
  "APPLE_WWDR_CERTIFICATE_PATH"
]

env_file = Path.expand("../.env", __DIR__)

if File.exists?(env_file) do
  env_file
  |> File.stream!()
  |> Enum.each(fn line ->
    line = String.trim(line)

    if line != "" and not String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          if key in wallet_keys and System.get_env(key) in [nil, ""] do
            value =
              value
              |> String.trim()
              |> String.trim_leading("\"")
              |> String.trim_trailing("\"")
              |> String.trim_leading("'")
              |> String.trim_trailing("'")

            if value != "" do
              System.put_env(key, value)
            end
          end

        _ ->
          :ok
      end
    end
  end)
end
