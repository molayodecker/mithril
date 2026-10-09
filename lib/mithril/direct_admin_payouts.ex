defmodule Mithril.DirectAdminPayouts do
  @moduledoc "Staff cleaner payout queue and wallet balances."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  @pending_statuses ~w(pending processing queued)

  def list(user_id, params \\ %{}) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_staff(uid),
         {:ok, status} <- optional_status_filter(params) do
      with {:ok, summary} <- load_summary(),
           {:ok, payouts} <- load_payouts(status) do
        {:ok, %{summary: summary, payouts: payouts}}
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_summary do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'currency', 'GHS',
             'owedMinor', COALESCE((
               SELECT sum(w.balance_subunit)::bigint
               FROM public.wallets w
               JOIN public.cleaner_data cd ON cd.user_id = w.user_id
               WHERE COALESCE(w.balance_subunit, 0) > 0
             ), 0),
             'cleanersWithBalance', COALESCE((
               SELECT count(*)::integer
               FROM public.wallets w
               JOIN public.cleaner_data cd ON cd.user_id = w.user_id
               WHERE COALESCE(w.balance_subunit, 0) > 0
             ), 0),
             'pendingCount', COALESCE((
               SELECT count(*)::integer
               FROM public.cleaner_payouts cp
               WHERE lower(cp.status) = ANY($1::text[])
             ), 0),
             'pendingMinor', COALESCE((
               SELECT sum(cp.amount)::bigint
               FROM public.cleaner_payouts cp
               WHERE lower(cp.status) = ANY($1::text[])
             ), 0),
             'paidThisWeekMinor', COALESCE((
               SELECT sum(cp.amount)::bigint
               FROM public.cleaner_payouts cp
               WHERE lower(cp.status) IN ('success', 'paid', 'completed')
                 AND cp.created_at >= date_trunc('week', timezone('Africa/Accra', now()))
             ), 0)
           )
           """,
           [@pending_statuses]
         ) do
      {:ok, %{rows: [[summary]]}} -> {:ok, summary}
      {:error, error} -> database_error(error)
    end
  end

  defp load_payouts(status_filter) do
    {clause, args} =
      case status_filter do
        nil ->
          {"", []}

        "pending" ->
          {"AND lower(cp.status) = ANY($1::text[])", [@pending_statuses]}

        "paid" ->
          {"AND lower(cp.status) IN ('success', 'paid', 'completed')", []}

        "failed" ->
          {"AND lower(cp.status) IN ('failed', 'reversed')", []}

        _ ->
          {"AND lower(cp.status) = $1", [status_filter]}
      end

    case Repo.query(
           """
           SELECT jsonb_build_object(
             'id', cp.id,
             'cleanerUserId', cp.user_id,
             'cleanerName', COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               'Cleaner'
             ),
             'amountMinor', cp.amount,
             'currency', cp.currency,
             'status', cp.status,
             'reference', cp.reference,
             'payoutMethodLabel', COALESCE(
               NULLIF(btrim(concat_ws(' · ', pm.bank_name, pm.masked_account)), ''),
               NULLIF(btrim(pm.account_name), ''),
               'Payout account'
             ),
             'recentJobsCount', COALESCE(jobs.count, 0),
             'createdAt', cp.created_at,
             'errorMessage', NULLIF(btrim(cp.error_message), '')
           )
           FROM public.cleaner_payouts cp
           LEFT JOIN public.profiles p ON p.id = cp.user_id
           LEFT JOIN LATERAL (
             SELECT pm.bank_name, pm.masked_account, pm.account_name
             FROM public.payout_methods pm
             WHERE pm.user_id = cp.user_id
             ORDER BY COALESCE(pm.is_primary, false) DESC,
                      COALESCE(pm.is_default, false) DESC,
                      pm.updated_at DESC NULLS LAST
             LIMIT 1
           ) pm ON true
           LEFT JOIN LATERAL (
             SELECT count(*)::integer AS count
             FROM public.bookings b
             WHERE b.cleaner_id = cp.user_id
               AND b.status = 'completed'
               AND b.scheduled_date >= (timezone('Africa/Accra', now()))::date - 7
           ) jobs ON true
           WHERE true
           #{clause}
           ORDER BY cp.created_at DESC
           LIMIT 120
           """,
           args
         ) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &first_row/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp optional_status_filter(params) do
    raw = params["status"] || params[:status]

    status =
      case raw do
        nil -> nil
        "" -> nil
        value when is_binary(value) -> String.downcase(String.trim(value))
        _ -> :invalid
      end

    if status == :invalid, do: {:error, :invalid_request}, else: {:ok, status}
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

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_column}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin payouts database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
