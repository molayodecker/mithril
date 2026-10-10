defmodule Mithril.DirectAdminTeam do
  @moduledoc "Staff roster: admin and reviewer roles."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  @staff_roles ~w(admin reviewer)

  def list(user_id) do
    with {:ok, _uid} <- dump_uuid(user_id),
         :ok <- require_admin_user(user_id) do
      case Repo.query(
             """
             SELECT jsonb_build_object(
               'userId', u.id,
               'name', COALESCE(
                 NULLIF(btrim(p.fullname), ''),
                 NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
                 NULLIF(btrim(u.email), ''),
                 NULLIF(btrim(u.phone), ''),
                 'Team member'
               ),
               'email', u.email,
               'phone', u.phone,
               'roles', COALESCE(roles.role_ids, '[]'::jsonb)
             )
             FROM public.users u
             JOIN (
               SELECT user_id, jsonb_agg(DISTINCT role_id ORDER BY role_id) AS role_ids
               FROM public.user_roles
               WHERE role_id = ANY($1::text[])
               GROUP BY user_id
             ) roles ON roles.user_id = u.id
             LEFT JOIN public.profiles p ON p.id = u.id
             ORDER BY
               CASE WHEN roles.role_ids ? 'admin' THEN 0 ELSE 1 END,
               COALESCE(p.fullname, u.email, u.phone, '') ASC
             LIMIT 200
             """,
             [@staff_roles]
           ) do
        {:ok, result} ->
          {:ok,
           %{
             members: Enum.map(result.rows, &first_row/1),
             roleGuide: role_guide()
           }}

        {:error, error} ->
          database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp role_guide do
    [
      %{
        "role" => "admin",
        "label" => "Admin",
        "access" => "Full ops desk, payouts, policy, cleaners"
      },
      %{
        "role" => "reviewer",
        "label" => "Reviewer",
        "access" => "Bookings, inbox, reports, read-most desks"
      }
    ]
  end

  defp require_admin_user(user_id) when is_binary(user_id) do
    if Auth.admin?(user_id), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp first_row([row]), do: row
  defp first_row(row) when is_map(row), do: row

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin team database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
