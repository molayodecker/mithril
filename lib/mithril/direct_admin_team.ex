defmodule Mithril.DirectAdminTeam do
  @moduledoc "Staff roster: admin and reviewer roles."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  @staff_roles ~w(admin reviewer)

  def grant(actor_id, params) when is_map(params) do
    with {:ok, _actor} <- dump_uuid(actor_id),
         :ok <- require_admin_user(actor_id),
         {:ok, grant_attrs} <- grant_attrs(params),
         {:ok, user} <- Auth.grant_staff(grant_attrs),
         {:ok, member} <- fetch_member(user.id) do
      {:ok, member}
    else
      :error -> {:error, :invalid_request}
      {:error, :not_found} -> {:error, :user_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke(actor_id, params) when is_map(params) do
    with {:ok, actor_uid} <- cast_uuid(actor_id),
         :ok <- require_admin_user(actor_id),
         {:ok, target_uid} <- cast_uuid(params["userId"] || params[:userId]),
         {:ok, role} <- staff_role(params["role"] || params[:role]),
         :ok <- ensure_can_revoke(actor_uid, target_uid, role),
         :ok <- Auth.revoke_staff_role(target_uid, role),
         {:ok, member} <- fetch_member(target_uid) do
      {:ok, member}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def list(user_id) do
    with {:ok, _uid} <- dump_uuid(user_id),
         :ok <- require_admin_user(user_id) do
      case Repo.query(
             """
             SELECT jsonb_build_object(
               'userId', u.id::text,
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

  defp grant_attrs(params) do
    role = params["role"] || params[:role]
    user_id = blank(params["userId"] || params[:userId])
    email = blank(params["email"] || params[:email])
    phone = blank(params["phone"] || params[:phone])

    cond do
      role not in @staff_roles ->
        {:error, :invalid_role}

      is_binary(user_id) or is_binary(email) or is_binary(phone) ->
        {:ok, %{role: role, user_id: user_id, email: email, phone: phone}}

      true ->
        {:error, :invalid_request}
    end
  end

  defp staff_role(role) when role in @staff_roles, do: {:ok, role}
  defp staff_role(_), do: {:error, :invalid_role}

  defp ensure_can_revoke(actor_uid, target_uid, "admin") do
    if canonical_uuid(actor_uid) == canonical_uuid(target_uid) and admin_count() <= 1 do
      {:error, :last_admin}
    else
      :ok
    end
  end

  defp ensure_can_revoke(_actor_uid, _target_uid, _role), do: :ok

  defp admin_count do
    case Repo.query("SELECT COUNT(*)::integer FROM public.user_roles WHERE role_id = 'admin'") do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp fetch_member(user_id) when is_binary(user_id) do
    with {:ok, uid} <- dump_uuid(user_id) do
      case Repo.query(
             """
             SELECT jsonb_build_object(
               'userId', u.id::text,
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
             LEFT JOIN (
               SELECT user_id, jsonb_agg(DISTINCT role_id ORDER BY role_id) AS role_ids
               FROM public.user_roles
               WHERE user_id = $1::uuid AND role_id = ANY($2::text[])
               GROUP BY user_id
             ) roles ON roles.user_id = u.id
             LEFT JOIN public.profiles p ON p.id = u.id
             WHERE u.id = $1::uuid
             LIMIT 1
             """,
             [uid, @staff_roles]
           ) do
        {:ok, %{rows: [[member]]}} -> {:ok, member}
        {:ok, _} -> {:error, :not_found}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_request}
    end
  end

  defp require_admin_user(user_id) when is_binary(user_id) do
    if Auth.admin?(user_id), do: :ok, else: {:error, :forbidden}
  end

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank(_), do: nil

  defp dump_uuid(value) when is_binary(value) do
    with {:ok, canonical} <- cast_uuid(value) do
      Ecto.UUID.dump(canonical)
    end
  end

  defp dump_uuid(_), do: :error

  defp cast_uuid(value) when is_binary(value) do
    case byte_size(value) do
      16 ->
        case Ecto.UUID.load(value) do
          {:ok, canonical} -> {:ok, canonical}
          :error -> :error
        end

      _ ->
        case Ecto.UUID.cast(String.trim(value)) do
          {:ok, canonical} -> {:ok, canonical}
          :error -> :error
        end
    end
  end

  defp cast_uuid(_), do: :error

  defp canonical_uuid(value) when is_binary(value) do
    case cast_uuid(value) do
      {:ok, canonical} -> canonical
      :error -> value
    end
  end

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
