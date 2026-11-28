defmodule Mithril.FamilyCareVisits do
  @moduledoc """
  Creates the visits covered by one Family Care charge and reuses them on retry.
  """

  alias Mithril.FamilyCareSchedule
  alias Mithril.Repo

  @spec settle(Ecto.UUID.t() | String.t()) :: :ok | {:error, term()}
  def settle(booking_id) do
    with true <- schedule_storage_ready?(),
         {:ok, anchor} <- load_anchor(booking_id),
         :ok <- ensure_visits(anchor),
         :ok <- mark_period_paid(anchor.id) do
      :ok
    else
      false -> :ok
      :skip -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_storage_ready? do
    case Repo.query("""
         SELECT 1
         FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = 'subscriptions'
           AND column_name = 'family_care_schedule'
         """) do
      {:ok, %{num_rows: 1}} -> true
      _ -> false
    end
  end

  defp load_anchor(booking_id) do
    case Repo.query(
           """
           SELECT anchor.id,
                  anchor.scheduled_date,
                  anchor.subscription_id,
                  anchor.covered_by_booking_id,
                  schedule.family_care_schedule
           FROM public.bookings requested
           JOIN public.bookings anchor
             ON anchor.id = COALESCE(requested.covered_by_booking_id, requested.id)
           LEFT JOIN public.subscriptions schedule
             ON schedule.id = anchor.subscription_id
           WHERE requested.id = $1
           LIMIT 1
           """,
           [dump_id(booking_id)]
         ) do
      {:ok, %{rows: [[id, scheduled_date, subscription_id, _covered_by, schedule]]}} ->
        {:ok,
         %{
           id: id,
           scheduled_date: scheduled_date,
           subscription_id: subscription_id,
           schedule: decode_schedule(schedule)
         }}

      {:ok, %{rows: []}} ->
        :skip

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_visits(%{schedule: nil}), do: :ok
  defp ensure_visits(%{subscription_id: nil}), do: :ok

  defp ensure_visits(anchor) do
    dates = FamilyCareSchedule.visit_dates(anchor.schedule, anchor.scheduled_date)

    period_start =
      FamilyCareSchedule.period_start(anchor.schedule["frequency"], anchor.scheduled_date)

    with :ok <- set_period_start(anchor.id, period_start),
         :ok <- insert_missing(anchor.id, period_start, dates) do
      :ok
    end
  end

  defp set_period_start(anchor_id, period_start) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET billing_period_start = $2::date, updated_at = now()
           WHERE id = $1
             AND billing_period_start IS NULL
           """,
           [anchor_id, period_start]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp insert_missing(anchor_id, period_start, dates) do
    case Repo.query(
           """
           INSERT INTO public.bookings (
             customer_id,
             cleaner_id,
             direct_assigned_cleaner_id,
             service_id,
             title,
             scheduled_date,
             scheduled_time,
             duration_hours,
             duration_final,
             address,
             special_instructions,
             total_price,
             final_amount_minor,
             core_amount_minor,
             currency,
             status,
             payment_status,
             timezone,
             subscription_id,
             pricing_version,
             booking_cover,
             booking_cover_amount,
             platform_fee,
             cleaner_earnings_minor,
             supplies_option,
             supplies_allowance_minor,
             idempotency_key,
             recurrence_interval,
             billing_period_start,
             covered_by_booking_id
           )
           SELECT
             anchor.customer_id,
             anchor.cleaner_id,
             anchor.direct_assigned_cleaner_id,
             anchor.service_id,
             anchor.title,
             visit.visit_date,
             anchor.scheduled_time,
             anchor.duration_hours,
             anchor.duration_final,
             anchor.address,
             anchor.special_instructions,
             0,
             0,
             0,
             anchor.currency,
             'pending',
             'pending',
             anchor.timezone,
             anchor.subscription_id,
             anchor.pricing_version,
             false,
             0,
             0,
             0,
             anchor.supplies_option,
             0,
             'family-care-visit:' || anchor.subscription_id::text || ':' || $2::date || ':' || visit.visit_date,
             anchor.recurrence_interval,
             $2::date,
             anchor.id
           FROM public.bookings anchor
           CROSS JOIN unnest($3::date[]) AS visit(visit_date)
           WHERE anchor.id = $1
             AND visit.visit_date <> anchor.scheduled_date
             AND NOT EXISTS (
               SELECT 1
               FROM public.bookings existing
               WHERE existing.subscription_id = anchor.subscription_id
                 AND existing.billing_period_start = $2::date
                 AND existing.scheduled_date = visit.visit_date
                 AND existing.status::text <> 'cancelled'
             )
           """,
           [anchor_id, period_start, dates]
         ) do
      {:ok, _} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp mark_period_paid(anchor_id) do
    case Repo.query(
           """
           UPDATE public.bookings sibling
           SET payment_status = anchor.payment_status,
               payment_method = anchor.payment_method,
               reference = anchor.reference,
               status = CASE
                 WHEN sibling.status = 'pending' AND anchor.status::text IN ('confirmed', 'scheduled')
                   THEN anchor.status
                 ELSE sibling.status
               END,
               updated_at = now()
           FROM public.bookings anchor
           WHERE anchor.id = $1
             AND sibling.covered_by_booking_id = anchor.id
             AND sibling.status::text NOT IN ('cancelled', 'completed')
           """,
           [anchor_id]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp decode_schedule(nil), do: nil
  defp decode_schedule(%{} = schedule), do: schedule

  defp decode_schedule(schedule) when is_binary(schedule) do
    case Jason.decode(schedule) do
      {:ok, %{} = decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_schedule(_schedule), do: nil

  defp dump_id(id) when is_binary(id) and byte_size(id) == 16, do: id
  defp dump_id(id) when is_binary(id), do: Ecto.UUID.dump!(id)
end
