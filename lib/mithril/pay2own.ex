defmodule Mithril.Pay2Own do
  @moduledoc """
  Tells Pay2Own whether a worker already has a Mithril account.

  Pay2Own stores the order slip itself. This module only answers the lookup.
  """

  alias Mithril.Auth
  alias Mithril.Auth.Phone
  alias Mithril.Repo

  def account?(params) when is_map(params) do
    variants = phone_variants(param(params, "phone"))
    worker_id = worker_uuid(param(params, "workerId") || param(params, "worker_id"))

    if variants == [] and worker_id == "" do
      {:ok, false}
    else
      case Repo.query(
             """
             SELECT EXISTS (
               SELECT 1
               FROM public.users u
               INNER JOIN public.user_roles r
                 ON r.user_id = u.id AND r.role_id = 'cleaner'
               WHERE ($1::text[] <> '{}' AND u.phone = ANY($1::text[]))
                  OR ($2 <> '' AND u.id::text = $2)
             )
             """,
             [variants, worker_id]
           ) do
        {:ok, %{rows: [[account]]}} when is_boolean(account) -> {:ok, account}
        {:ok, _} -> {:ok, false}
        {:error, _error} -> {:error, :unavailable}
      end
    end
  end

  def account?(_), do: {:ok, false}

  defp phone_variants(value) do
    case Phone.normalize(to_string(value || "")) do
      {:ok, e164} -> Auth.phone_lookup_variants(e164)
      :error -> []
    end
  end

  defp worker_uuid(value) do
    case Ecto.UUID.cast(to_string(value || "")) do
      {:ok, uuid} -> uuid
      :error -> ""
    end
  end

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
