defmodule Mithril.DirectAdminAccounts do
  @moduledoc "Admin account maintenance (merge duplicates)."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  def merge(actor_id, params) when is_map(params) do
    with {:ok, actor_uid} <- cast_uuid(actor_id),
         :ok <- require_admin_user(actor_id),
         :ok <- ensure_merge_available(),
         {:ok, primary_uid} <- cast_uuid(params["primaryUserId"] || params[:primaryUserId]),
         {:ok, secondary_uid} <- cast_uuid(params["secondaryUserId"] || params[:secondaryUserId]),
         :ok <- ensure_distinct_users(primary_uid, secondary_uid) do
      case Repo.query(
             "SELECT public.merge_user_accounts($1::uuid, $2::uuid, $3::uuid)",
             [dump_uuid!(primary_uid), dump_uuid!(secondary_uid), dump_uuid!(actor_uid)]
           ) do
        {:ok, %{rows: [[snapshot]]}} ->
          {:ok,
           %{
             primaryUserId: primary_uid,
             secondaryUserId: secondary_uid,
             snapshot: decode_snapshot(snapshot)
           }}

        {:error, error} ->
          map_merge_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_merge_available do
    case Repo.query(
           "SELECT to_regprocedure('public.merge_user_accounts(uuid, uuid, uuid)') IS NOT NULL"
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :missing_function}
      {:ok, _} -> {:error, :missing_function}
      {:error, error} -> database_error(error)
    end
  end

  defp ensure_distinct_users(primary_uid, secondary_uid) do
    if primary_uid == secondary_uid, do: {:error, :same_user}, else: :ok
  end

  defp decode_snapshot(value) when is_map(value), do: value

  defp decode_snapshot(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => value}
    end
  end

  defp decode_snapshot(value), do: %{"raw" => value}

  defp map_merge_error(%Postgrex.Error{postgres: %{message: message}} = error)
       when is_binary(message) do
    reason =
      cond do
        String.contains?(message, "same_user") -> :same_user
        String.contains?(message, "primary_not_found") -> :primary_not_found
        String.contains?(message, "secondary_not_found") -> :secondary_not_found
        String.contains?(message, "secondary_is_privileged") -> :secondary_is_privileged
        String.contains?(message, "merge_wallet_currency_mismatch") -> :merge_wallet_currency_mismatch
        String.contains?(message, "invalid_user_ids") -> :invalid_request
        true -> nil
      end

    if reason, do: {:error, reason}, else: database_error(error)
  end

  defp map_merge_error(error), do: database_error(error)

  defp require_admin_user(user_id) when is_binary(user_id) do
    if Auth.admin?(user_id), do: :ok, else: {:error, :forbidden}
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> :error
    end
  end

  defp cast_uuid(_), do: :error

  defp dump_uuid!(value) do
    case Ecto.UUID.dump(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "invalid uuid"
    end
  end

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_function}}) do
    {:error, :missing_function}
  end

  defp database_error(error) do
    Logger.error("Direct admin accounts database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
