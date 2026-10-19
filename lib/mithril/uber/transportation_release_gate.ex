defmodule Mithril.Uber.TransportationReleaseGate do
  @moduledoc false

  alias Mithril.Repo

  @flag_key "BOOKING_UBER_TRANSPORTATION"
  @flag_channel "production"

  @spec sync(boolean(), DateTime.t()) :: {:ok, boolean()} | {:error, term()}
  def sync(enabled, evaluated_at) when is_boolean(enabled) do
    case Repo.transaction(fn ->
           with {:ok, current_enabled, prior_evaluation_at} <- read_current_enabled(),
                :ok <- ensure_fresh(evaluated_at, prior_evaluation_at),
                :ok <- maybe_write(enabled, current_enabled, evaluated_at),
                :ok <- maybe_revoke(enabled) do
             enabled
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, enabled} -> {:ok, enabled}
      {:error, :stale_evaluation} -> current_enabled()
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_enabled do
    case Repo.query(
           "SELECT enabled FROM public.app_feature_flags WHERE key = $1 AND channel = $2",
           [@flag_key, @flag_channel]
         ) do
      {:ok, %{rows: [[enabled]]}} when is_boolean(enabled) -> {:ok, enabled}
      _ -> {:error, :flag_unavailable}
    end
  end

  defp ensure_fresh(%DateTime{} = evaluated_at, %DateTime{} = prior_evaluation_at) do
    if DateTime.compare(evaluated_at, prior_evaluation_at) == :lt,
      do: {:error, :stale_evaluation},
      else: :ok
  end

  defp ensure_fresh(_, _), do: :ok

  # Record every completed evaluation, even if the flag value did not change.
  defp maybe_write(enabled, _current, evaluated_at), do: write_enabled(enabled, evaluated_at)

  defp maybe_revoke(true), do: :ok
  defp maybe_revoke(false), do: revoke_quotes()

  defp read_current_enabled do
    sql = """
    SELECT enabled, evaluated_at
    FROM public.app_feature_flags
    WHERE key = $1 AND channel = $2
    LIMIT 1 FOR UPDATE
    """

    case Repo.query(sql, [@flag_key, @flag_channel]) do
      {:ok, %{rows: [[enabled, prior_evaluation_at]]}} when is_boolean(enabled) ->
        {:ok, enabled, prior_evaluation_at}

      {:ok, %{rows: [[enabled, prior_evaluation_at]]}} when enabled in [true, false] ->
        {:ok, enabled == true, prior_evaluation_at}

      {:ok, %{rows: []}} ->
        {:ok, false, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  defp write_enabled(enabled, evaluated_at) do
    case Repo.query(
           """
           UPDATE public.app_feature_flags
           SET enabled = $1, updated_at = clock_timestamp(), evaluated_at = $2::timestamptz
           WHERE key = $3 AND channel = $4
           """,
           [enabled, evaluated_at, @flag_key, @flag_channel]
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
