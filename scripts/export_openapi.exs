# Enable the HTTP endpoint before the OTP application boots.
# MIX_ENV=test compiles MithrilWeb.Endpoint with server: false, so PHX_SERVER
# and this put_env must happen prior to Application.ensure_all_started/1.
endpoint = Application.get_env(:mithril, MithrilWeb.Endpoint, [])

Application.put_env(
  :mithril,
  MithrilWeb.Endpoint,
  Keyword.put(endpoint, :server, true),
  persistent: true
)

{:ok, _} = Application.ensure_all_started(:mithril)

Process.sleep(:infinity)
