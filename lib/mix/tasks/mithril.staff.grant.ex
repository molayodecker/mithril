defmodule Mix.Tasks.Mithril.Staff.Grant do
  @shortdoc "Grant admin or reviewer for Direct dispatch"

  @moduledoc """
  Grants `admin` or `reviewer` to an existing Instaclean user so they can
  use `/direct/admin/*` after a normal Mithril login.

      mix mithril.staff.grant --phone +233555000000 --role reviewer
      mix mithril.staff.grant --email you@tryinstaclean.com --role admin

  `STAFF_EMAIL`, `STAFF_PHONE`, and `STAFF_ROLE` can be used instead of flags.
  The user must already exist. Sign in through `/auth`, then `GET /auth/me`
  returns `"admin"` and/or `"reviewer"`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [email: :string, phone: :string, role: :string])

    email = Keyword.get(opts, :email) || System.get_env("STAFF_EMAIL")
    phone = Keyword.get(opts, :phone) || System.get_env("STAFF_PHONE")
    role = Keyword.get(opts, :role) || System.get_env("STAFF_ROLE") || "admin"

    attrs =
      %{role: role}
      |> maybe_put(:email, email)
      |> maybe_put(:phone, phone)

    if map_size(attrs) == 1 do
      Mix.raise("Provide --email or --phone (and optionally --role admin|reviewer)")
    else
      grant(attrs)
    end
  end

  defp grant(attrs) do
    case Mithril.Auth.grant_staff(attrs) do
      {:ok, user} ->
        Mix.shell().info("Granted #{user.role} to #{user.email || user.phone} (#{user.id})")

        Mix.shell().info("Sign in through /auth, then GET /auth/me.")

      {:error, reason} ->
        Mix.raise("Could not grant staff role: #{inspect(reason)}")
    end
  end

  defp maybe_put(attrs, _key, value) when value in [nil, ""], do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end
