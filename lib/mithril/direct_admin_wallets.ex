defmodule Mithril.DirectAdminWallets do
  @moduledoc "Staff reads and credits for worker wallets."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  def show(user_id, worker_id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, worker_uid} <- dump_uuid(worker_id),
         :ok <- require_admin(admin_uid) do
      case Repo.query(
             """
             SELECT w.balance_subunit, COALESCE(w.currency, 'GHS')
             FROM public.cleaner_data cd
             LEFT JOIN public.wallets w ON w.user_id = cd.user_id
             WHERE cd.user_id = $1::uuid
             """,
             [worker_uid]
           ) do
        {:ok, %{rows: []}} ->
          {:error, :worker_not_found}

        {:ok, %{rows: [[balance, currency]]}} ->
          {:ok,
           %{
             "balanceMinor" => balance,
             "currency" => currency || "GHS"
           }}

        {:error, error} ->
          database_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def credit(user_id, worker_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, worker_uid} <- dump_uuid(worker_id),
         {:ok, amount} <- positive_int(params["amountMinor"] || params[:amountMinor]),
         :ok <- require_admin(admin_uid),
         {:ok, notes} <- optional_notes(params["notes"] || params[:notes]) do
      case Repo.query(
             """
             SELECT public.record_admin_wallet_credit(
               p_worker_id := $1::uuid,
               p_amount_subunit := $2::integer,
               p_recorded_by := $3::uuid,
               p_notes := $4::text
             )
             """,
             [worker_uid, amount, admin_uid, notes]
           ) do
        {:ok, %{rows: [[payload]]}} ->
          {:ok,
           %{
             "amountMinor" => amount,
             "newBalanceMinor" => rpc_int(payload, "new_balance_subunit"),
             "currency" => payload["currency"] || payload[:currency] || "GHS"
           }}

        {:error, error} ->
          map_rpc_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp positive_int(value) when is_integer(value) and value > 0 and value <= 2_147_483_647,
    do: {:ok, value}

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> positive_int(parsed)
      _ -> {:error, :invalid_amount}
    end
  end

  defp positive_int(_), do: {:error, :invalid_amount}

  defp optional_notes(nil), do: {:ok, nil}

  defp optional_notes(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > 500 -> {:error, :invalid_notes}
      true -> {:ok, trimmed}
    end
  end

  defp optional_notes(_), do: {:error, :invalid_notes}

  defp rpc_int(payload, key) when is_map(payload) do
    value = payload[key] || payload[String.to_atom(key)]
    if is_integer(value), do: value, else: nil
  end

  defp rpc_int(_, _), do: nil

  defp map_rpc_error(%Postgrex.Error{postgres: %{message: message}} = error)
       when is_binary(message) do
    cond do
      String.contains?(message, "worker_not_found") -> {:error, :worker_not_found}
      String.contains?(message, "wallet_not_found") -> {:error, :wallet_not_found}
      String.contains?(message, "invalid_amount") -> {:error, :invalid_amount}
      String.contains?(message, "invalid_notes") -> {:error, :invalid_notes}
      String.contains?(message, "unsupported_currency") -> {:error, :unsupported_currency}
      String.contains?(message, "amount_too_large") -> {:error, :amount_too_large}
      String.contains?(message, "recorded_by_not_authorized") -> {:error, :forbidden}
      String.contains?(message, "undefined_function") -> {:error, :database_unavailable}
      true -> database_error(error)
    end
  end

  defp map_rpc_error(error), do: database_error(error)

  defp database_error(error) do
    Logger.error("Direct admin wallet database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
