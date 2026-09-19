defmodule Mix.Tasks.Mithril.Admin.Create do
  @shortdoc "Grant the Instaclean admin role for Mithril API login"

  @moduledoc """
  Creates or updates an Instaclean user with the `admin` role so the
  frontend can call `/direct/admin/*` after a normal Mithril auth login.

      mix mithril.admin.create --email you@tryinstaclean.com --password '...'
      mix mithril.admin.create --phone +233555000000
      mix mithril.admin.create --phone +233555000000 --password '...'

  Phone-only admins sign in with `POST /auth/otp` and `POST /auth/otp/verify`.
  Email logins still need a password via `POST /auth/login`. `GET /auth/me`
  then returns `"admin": true`. `ADMIN_EMAIL`, `ADMIN_PHONE`, and
  `ADMIN_PASSWORD` can be used instead of the flags.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [email: :string, phone: :string, password: :string])

    email = Keyword.get(opts, :email) || System.get_env("ADMIN_EMAIL")
    phone = Keyword.get(opts, :phone) || System.get_env("ADMIN_PHONE")
    password = Keyword.get(opts, :password) || System.get_env("ADMIN_PASSWORD")

    attrs =
      %{}
      |> maybe_put(:email, email)
      |> maybe_put(:phone, phone)
      |> maybe_put(:password, password)

    if map_size(attrs) == 0 do
      Mix.raise("Provide --email and --password, --phone, or ADMIN_EMAIL / ADMIN_PHONE")
    else
      provision(attrs)
    end
  end

  defp provision(attrs) do
    case Mithril.Auth.provision_admin(attrs) do
      {:ok, user} ->
        Mix.shell().info("Admin API login ready for #{user.email || user.phone} (#{user.id})")

        Mix.shell().info(
          "Sign in through /auth, then GET /auth/me. Keep Mithril pointed at the intended database."
        )

      {:error, reason} ->
        Mix.raise("Could not create admin login: #{inspect(reason)}")
    end
  end

  defp maybe_put(attrs, _key, value) when value in [nil, ""], do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end
