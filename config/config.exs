import Config

config :mithril,
  ecto_repos: [Mithril.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :mithril, MithrilWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MithrilWeb.ErrorJSON], layout: false],
  pubsub_server: Mithril.PubSub

config :phoenix, :json_library, Jason

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
