defmodule Mithril.DirectAdminTeam do
  @moduledoc "Staff roster: admin and reviewer roles."

  require Logger

  alias Mithril.Auth
  alias Mithril.OpsPermissions
  alias Mithril.Repo

  @staff_roles ~w(admin reviewer)
  @roster_roles @staff_roles ++ OpsPermissions.ids()

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
    with {:ok, _actor_uid} <- cast_uuid(actor_id),
         :ok <- require_admin_user(actor_id),
         {:ok, target_uid} <- cast_uuid(params["userId"] || params[:userId]),
         {:ok, role} <- staff_role(params["role"] || params[:role]),
         {:ok, member} <- revoke_role_transaction(target_uid, role) do
      {:ok, member}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_access(actor_id, params) when is_map(params) do
    with {:ok, _actor} <- dump_uuid(actor_id),
         :ok <- require_admin_user(actor_id),
         {:ok, target_uid} <- resolve_target_user(params),
         {:ok, staff_roles} <- parse_staff_roles(params),
         {:ok, permissions} <- parse_permissions(params),
         {:ok, staff_roles} <- ensure_staff_gate(staff_roles, permissions),
         :ok <- validate_access_payload(staff_roles, permissions),
         {:ok, member} <- sync_access_transaction(target_uid, staff_roles, permissions) do
      {:ok, member}
    else
      :error -> {:error, :invalid_request}
      {:error, :not_found} -> {:error, :user_not_found}
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
             [@roster_roles]
           ) do
        {:ok, result} ->
          {:ok,
           %{
             members: Enum.map(result.rows, &encode_member(first_row(&1))),
             roleGuide: role_guide(),
             permissionCatalog: OpsPermissions.catalog()
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

  defp resolve_target_user(params) do
    case Auth.find_user_for_staff_access(params) do
      {:ok, user} -> {:ok, user.id}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_staff_roles(params) do
    raw = params["staffRoles"] || params[:staffRoles] || params["roles"] || params[:roles] || []

    if is_list(raw) do
      staff = Enum.filter(raw, &(&1 in @staff_roles)) |> Enum.uniq()
      {:ok, staff}
    else
      {:error, :invalid_request}
    end
  end

  defp parse_permissions(params) do
    raw = params["permissions"] || params[:permissions] || []

    if is_list(raw) do
      permissions = Enum.filter(raw, &OpsPermissions.valid?/1) |> Enum.uniq()
      {:ok, permissions}
    else
      {:error, :invalid_request}
    end
  end

  defp ensure_staff_gate(staff_roles, permissions) do
    cond do
      staff_roles != [] -> {:ok, staff_roles}
      permissions == [] -> {:ok, staff_roles}
      true -> {:ok, ["reviewer"]}
    end
  end

  defp validate_access_payload(staff_roles, permissions) do
    if staff_roles == [] and permissions == [] do
      {:error, :invalid_request}
    else
      :ok
    end
  end

  defp sync_access_transaction(target_uid, staff_roles, permissions) do
    case Repo.transaction(fn ->
           if "admin" not in staff_roles and Auth.admin?(target_uid) do
             Repo.query!("SELECT pg_advisory_xact_lock(107, 1)")

             case Repo.query(
                    "SELECT COUNT(*)::integer FROM public.user_roles WHERE role_id = 'admin'"
                  ) do
               {:ok, %{rows: [[count]]}} when count <= 1 ->
                 Repo.rollback(:last_admin)

               {:ok, _} ->
                 :ok

               {:error, error} ->
                 Repo.rollback(database_reason(error))
             end
           end

           with :ok <- Auth.sync_staff_roles(target_uid, staff_roles),
                :ok <- Auth.sync_ops_permissions(target_uid, permissions),
                {:ok, member} <- fetch_member(target_uid) do
             member
           else
             {:error, reason} -> Repo.rollback(reason)
             other -> Repo.rollback(other)
           end
         end) do
      {:ok, member} -> {:ok, member}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_member(member) when is_map(member) do
    all_roles = Map.get(member, "roles") || Map.get(member, :roles) || []

    {staff_roles, permissions} =
      case all_roles do
        roles when is_list(roles) -> OpsPermissions.split_roles(roles)
        _ -> {[], []}
      end

    member
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("roles", staff_roles)
    |> Map.put("permissions", permissions)
  end

  defp encode_member(member), do: member

  # Serialize role mutations that could remove the last admin. The count and
  # deletion must run in one transaction, not in separate requests.
  defp revoke_role_transaction(target_uid, role) do
    case Repo.transaction(fn ->
           if role == "admin" do
             Repo.query!("SELECT pg_advisory_xact_lock(107, 1)")

             case Repo.query(
                    "SELECT COUNT(*)::integer FROM public.user_roles WHERE role_id = 'admin'"
                  ) do
               {:ok, %{rows: [[count]]}} when count <= 1 ->
                 case Repo.query(
                        "SELECT 1 FROM public.user_roles WHERE user_id = $1::uuid AND role_id = 'admin'",
                        [Ecto.UUID.dump!(target_uid)]
                      ) do
                   {:ok, %{num_rows: 1}} -> Repo.rollback(:last_admin)
                   {:error, error} -> Repo.rollback(database_reason(error))
                   _ -> :ok
                 end

               {:ok, _} ->
                 :ok

               {:error, error} ->
                 Repo.rollback(database_reason(error))
             end
           end

           case Auth.revoke_staff_role(target_uid, role) do
             :ok ->
               case fetch_member(target_uid) do
                 {:ok, member} -> member
                 {:error, reason} -> Repo.rollback(reason)
               end

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, member} -> {:ok, member}
      {:error, reason} -> {:error, reason}
    end
  end

  defp database_reason(error) do
    case database_error(error) do
      {:error, reason} -> reason
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
             [uid, @roster_roles]
           ) do
        {:ok, %{rows: [[member]]}} -> {:ok, encode_member(member)}
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
