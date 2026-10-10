defmodule Mithril.DirectAdminReviews do
  @moduledoc "Staff booking reviews desk."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  def list(user_id, params \\ %{}) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_staff(uid),
         {:ok, filter} <- parse_filter(params),
         {:ok, stats} <- load_stats(),
         {:ok, reviews} <- load_reviews(filter) do
      {:ok, %{stats: stats, reviews: reviews}}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_stats do
    case Repo.query("""
         SELECT jsonb_build_object(
           'averageRating', COALESCE(round(avg(r.rating)::numeric, 1), 0),
           'thisMonthCount', count(*) FILTER (
             WHERE r.created_at >= date_trunc('month', timezone('utc', now()))
           )::integer,
           'lowRatingCount', count(*) FILTER (WHERE r.rating <= 2)::integer,
           'needsReplyCount', count(*) FILTER (
             WHERE NULLIF(btrim(r.comment), '') IS NOT NULL
               AND COALESCE(NULLIF(btrim(r.response), ''), '') = ''
           )::integer
         )
         FROM public.reviews r
         """) do
      {:ok, %{rows: [[stats]]}} -> {:ok, stats}
      {:error, error} -> database_error(error)
    end
  end

  defp load_reviews(filter) do
    clause =
      case filter do
        "low" ->
          "WHERE r.rating <= 2"

        "needs_reply" ->
          "WHERE NULLIF(btrim(r.comment), '') IS NOT NULL AND COALESCE(NULLIF(btrim(r.response), ''), '') = ''"

        "hidden" ->
          "WHERE COALESCE(r.status, 'published') <> 'published'"

        _ ->
          "WHERE true"
      end

    case Repo.query("""
         SELECT jsonb_build_object(
           'id', r.id,
           'bookingId', r.booking_id,
           'rating', r.rating,
           'comment', r.comment,
           'response', r.response,
           'status', COALESCE(r.status, 'published'),
           'createdAt', r.created_at,
           'reviewerName', COALESCE(
             NULLIF(btrim(rp.fullname), ''),
             NULLIF(btrim(concat_ws(' ', rp.firstname, rp.lastname)), ''),
             'Customer'
           ),
           'revieweeName', COALESCE(
             NULLIF(btrim(ep.fullname), ''),
             NULLIF(btrim(concat_ws(' ', ep.firstname, ep.lastname)), ''),
             'Professional'
           ),
           'serviceName', NULLIF(btrim(st.name), '')
         )
         FROM public.reviews r
         LEFT JOIN public.bookings b ON b.id = r.booking_id
         LEFT JOIN public.service_types st ON st.id = b.service_id
         LEFT JOIN public.profiles rp ON rp.id = COALESCE(r.reviewer_id, b.customer_id)
         LEFT JOIN public.profiles ep ON ep.id = COALESCE(r.reviewee_id, b.cleaner_id)
         #{clause}
         ORDER BY r.created_at DESC
         LIMIT 120
         """) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &first_row/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp parse_filter(params) do
    raw = params["filter"] || params[:filter] || "all"

    filter =
      case raw do
        value when value in ["all", "low", "needs_reply", "hidden"] -> value
        value when is_binary(value) -> String.downcase(String.trim(value))
        _ -> "all"
      end

    allowed = ~w(all low needs_reply hidden)
    {:ok, if(filter in allowed, do: filter, else: "all")}
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
    Logger.error("Direct admin reviews database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
