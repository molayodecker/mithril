defmodule Mithril.Uber.TransportationReleaseGate do
  @moduledoc false

  alias Mithril.Repo

  @flag_key "BOOKING_UBER_TRANSPORTATION"
  @flag_channel "production"

  @spec sync(boolean()) :: :ok | {:error, term()}
  def sync(enabled) when is_boolean(enabled) do
    case Repo.transaction(fn ->
           with {:ok, current_enabled} <- read_current_enabled(),
                :ok <- maybe_write(enabled, current_enabled),
                :ok <- maybe_revoke(enabled) do
             :ok
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_write(enabled, enabled), do: :ok
  defp maybe_write(enabled, _current), do: write_enabled(enabled)

  defp maybe_revoke(true), do: :ok
  defp maybe_revoke(false), do: revoke_quotes()

  defp read_current_enabled do
    sql = """
    SELECT enabled
    FROM public.app_feature_flags
    WHERE key = $1 AND channel = $2
    LIMIT 1 FOR UPDATE
    """

    case Repo.query(sql, [@flag_key, @flag_channel]) do
      {:ok, %{rows: [[enabled]]}} when is_boolean(enabled) -> {:ok, enabled}
      {:ok, %{rows: [[enabled]]}} when enabled in [true, false] -> {:ok, enabled == true}
      {:ok, %{rows: []}} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  defp write_enabled(enabled) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.query(
           """
           UPDATE public.app_feature_flags
           SET enabled = $1, updated_at = $2::timestamptz
           WHERE key = $3 AND channel = $4
           """,
           [enabled, now, @flag_key, @flag_channel]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :flag_missing}
      {:error, error} -> {:error, error}
    end
  end

  defp revoke_quotes do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.query(
           """
           UPDATE public.uber_transportation_quotes
           SET revoked_at = $1::timestamptz
           WHERE revoked_at IS NULL AND expires_at > $1::timestamptz
           """,
           [now]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
