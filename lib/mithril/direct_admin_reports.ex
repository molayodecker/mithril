defmodule Mithril.DirectAdminReports do
  @moduledoc "Staff operations summary aggregates from bookings."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  @allowed_days [7, 30, 90]
  @paid_statuses ~w(paid succeeded refunded partially_refunded)
  @cancelled_statuses ~w(cancelled canceled)

  def summary(user_id, params \\ %{}) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_staff(uid),
         {:ok, days} <- parse_days(params) do
      case Repo.query(
             """
             WITH bounds AS (
               SELECT
                 (timezone('Africa/Accra', now()))::date AS end_date,
                 ((timezone('Africa/Accra', now()))::date - ($1::integer - 1)) AS start_date,
                 ((timezone('Africa/Accra', now()))::date - ($1::integer * 2 - 1)) AS prev_start_date,
                 ((timezone('Africa/Accra', now()))::date - $1::integer) AS prev_end_date
             ),
             current_period AS (
               SELECT b.*
               FROM public.bookings b, bounds
               WHERE b.scheduled_date BETWEEN bounds.start_date AND bounds.end_date
             ),
             previous_period AS (
               SELECT b.*
               FROM public.bookings b, bounds
               WHERE b.scheduled_date BETWEEN bounds.prev_start_date AND bounds.prev_end_date
             ),
             current_metrics AS (
               SELECT
                 count(*)::integer AS bookings_count,
                 count(*) FILTER (
                   WHERE lower(b.status::text) = ANY($2::text[])
                 )::integer AS cancelled_count,
                 count(*) FILTER (WHERE b.cleaner_id IS NOT NULL)::integer AS assigned_count,
                 COALESCE(sum(
                   CASE
                     WHEN lower(COALESCE(b.payment_status::text, '')) = ANY($3::text[])

                     THEN GREATEST(
                       ROUND(COALESCE(b.final_amount_minor::numeric, b.total_price::numeric, 0)) -
                       COALESCE((
                         SELECT SUM(br.refund_amount_minor)::numeric
                         FROM public.booking_refunds br
                         WHERE br.booking_id = b.id AND br.status = 'processed'
                       ), 0),
                       0
                     )
                     ELSE 0
                   END
                 ), 0)::bigint AS revenue_minor,
                 count(*) FILTER (
                   WHERE lower(COALESCE(b.payment_status::text, '')) = ANY($3::text[])

                 )::integer AS paid_count
               FROM current_period b
             ),
             previous_metrics AS (
               SELECT COALESCE(sum(
                 CASE
                   WHEN lower(COALESCE(b.payment_status::text, '')) = ANY($3::text[])

                   THEN GREATEST(
                       ROUND(COALESCE(b.final_amount_minor::numeric, b.total_price::numeric, 0)) -
                       COALESCE((
                         SELECT SUM(br.refund_amount_minor)::numeric
                         FROM public.booking_refunds br
                         WHERE br.booking_id = b.id AND br.status = 'processed'
                       ), 0),
                       0
                     )
                   ELSE 0
                 END
               ), 0)::bigint AS revenue_minor
               FROM previous_period b
             ),
             daily AS (
               SELECT
                 b.scheduled_date::text AS day,
                 COALESCE(sum(
                   CASE
                     WHEN lower(COALESCE(b.payment_status::text, '')) = ANY($3::text[])

                     THEN GREATEST(
                       ROUND(COALESCE(b.final_amount_minor::numeric, b.total_price::numeric, 0)) -
                       COALESCE((
                         SELECT SUM(br.refund_amount_minor)::numeric
                         FROM public.booking_refunds br
                         WHERE br.booking_id = b.id AND br.status = 'processed'
                       ), 0),
                       0
                     )
                     ELSE 0
                   END
                 ), 0)::bigint AS revenue_minor
               FROM current_period b
               GROUP BY b.scheduled_date
               ORDER BY b.scheduled_date ASC
             ),
             top_areas AS (
               SELECT
                 COALESCE(NULLIF(btrim(split_part(COALESCE(b.address, ''), ',', 1)), ''), 'Unknown') AS area_name,
                 COALESCE(sum(
                   CASE
                     WHEN lower(COALESCE(b.payment_status::text, '')) = ANY($3::text[])

                     THEN GREATEST(
                       ROUND(COALESCE(b.final_amount_minor::numeric, b.total_price::numeric, 0)) -
                       COALESCE((
                         SELECT SUM(br.refund_amount_minor)::numeric
                         FROM public.booking_refunds br
                         WHERE br.booking_id = b.id AND br.status = 'processed'
                       ), 0),
                       0
                     )
                     ELSE 0
                   END
                 ), 0)::bigint AS revenue_minor
               FROM current_period b
               GROUP BY 1
               ORDER BY revenue_minor DESC
               LIMIT 5
             )
             SELECT jsonb_build_object(
               'days', $1::integer,
               'currency', 'GHS',
               'generatedAt', timezone('utc', now()),
               'revenueMinor', cm.revenue_minor,
               'revenueGrowthPercent', CASE
                 WHEN pm.revenue_minor = 0 THEN NULL
                 ELSE round(((cm.revenue_minor - pm.revenue_minor)::numeric / pm.revenue_minor::numeric) * 100, 1)
               END,
               'bookingsCount', cm.bookings_count,
               'cancelRatePercent', CASE
                 WHEN cm.bookings_count = 0 THEN 0
                 ELSE round((cm.cancelled_count::numeric / cm.bookings_count::numeric) * 100, 1)
               END,
               'fillRatePercent', CASE
                 WHEN cm.bookings_count = 0 THEN 0
                 ELSE round((cm.assigned_count::numeric / cm.bookings_count::numeric) * 100, 1)
               END,
               'avgOrderMinor', CASE
                 WHEN cm.paid_count = 0 THEN 0
                 ELSE (cm.revenue_minor / cm.paid_count)::bigint
               END,
               'dailyRevenue', COALESCE((SELECT jsonb_agg(jsonb_build_object('day', day, 'revenueMinor', revenue_minor)) FROM daily), '[]'::jsonb),
               'topAreas', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object('name', area_name, 'revenueMinor', revenue_minor) ORDER BY revenue_minor DESC)
                 FROM top_areas
               ), '[]'::jsonb)
             )
             FROM current_metrics cm, previous_metrics pm
             """,
             [days, @cancelled_statuses, @paid_statuses]
           ) do
        {:ok, %{rows: [[summary]]}} -> {:ok, summary}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_days(params) do
    raw = params["days"] || params[:days] || params["daysAhead"] || params[:daysAhead] || 30

    days =
      case raw do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {parsed, ""} -> parsed
            _ -> nil
          end

        _ ->
          nil
      end

    if days in @allowed_days, do: {:ok, days}, else: {:error, :invalid_request}
  end

  defp require_staff(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_column}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin reports database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
