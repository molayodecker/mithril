defmodule Mithril.DirectAdminServiceAreas do
  @moduledoc "Staff service area coverage with active cleaner counts."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  def list(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_staff(uid) do
      case Repo.query("""
           SELECT jsonb_build_object(
             'id', sa.id,
             'name', sa.name,
             'country', sa.country,
             'active', sa.active,
             'createdAt', sa.created_at,
             'cleanerCount', COALESCE((
               SELECT count(*)::integer
               FROM public.cleaner_data cd
               WHERE COALESCE(cd.status::text, 'active') = 'active'
                 AND sa.name = ANY(COALESCE(cd.service_areas, ARRAY[]::text[]))
             ), 0)
           )
           FROM public.service_areas sa
           ORDER BY sa.active DESC, sa.name ASC
           """) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &first_row/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_staff(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp first_row([row]), do: row
  defp first_row(row) when is_map(row), do: row

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin service areas database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
