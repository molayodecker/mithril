defmodule Mithril.Repo do
  use Ecto.Repo,
    otp_app: :mithril,
    adapter: Ecto.Adapters.Postgres
end
