defmodule Mithril.PropertyCalendar.TurnoverOpportunities do
  @moduledoc false

  alias Mithril.Repo

  @entry_buffer_minutes 15
  @guest_ready_buffer_minutes 30

  @spec recompute(map()) :: :ok | {:error, term()}
  def recompute(feed) do
    case Repo.query(
           """
           SELECT id, status, starts_at, ends_at
           FROM public.property_calendar_events
           WHERE calendar_feed_id = $1::uuid
             AND cancelled_at IS NULL
             AND status IN ('confirmed', 'unknown')
           ORDER BY starts_at ASC
           """,
           [feed["id"]]
         ) do
      {:ok, %{rows: rows}} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        minimum = feed["minimum_turnover_minutes"] || 180

        with :ok <-
               rows
               |> Enum.with_index()
               |> Enum.reduce_while(:ok, fn {[departing_id, _status, _starts_at, ends_at], index},
                                                   :ok ->
                 arriving = find_arriving(rows, index, ends_at)

                 case upsert_opportunity(feed, departing_id, ends_at, arriving, minimum, now) do
                   :ok -> {:cont, :ok}
                   {:error, error} -> {:halt, {:error, error}}
                 end
               end),
             :ok <- cancel_stale_opportunities(feed, rows, now) do
          :ok
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_arriving(rows, departing_index, ends_at) do
    checkout_ms = parse_ms(ends_at)

    rows
    |> Enum.drop(departing_index + 1)
    |> Enum.find_value(fn [_id, status, starts_at, _ends_at] = row ->
      if status == "blocked" do
        nil
      else
        if parse_ms(starts_at) > checkout_ms, do: row, else: nil
      end
    end)
  end

  defp upsert_opportunity(feed, departing_id, ends_at, arriving, minimum, now) do
    checkout_at = parse_dt(ends_at)
    next_checkin_at = if arriving, do: parse_dt(Enum.at(arriving, 2)), else: nil
    suggestion = compute_suggested(checkout_at, next_checkin_at, minimum)

    arriving_id = if arriving, do: Enum.at(arriving, 0), else: nil

    case Repo.query(
           """
           INSERT INTO public.turnover_opportunities (
        property_id, departing_event_id, arriving_event_id, checkout_at, next_checkin_at,
        suggested_start_at, suggested_duration_hours, status, source, updated_at
      ) VALUES (
        $1::uuid, $2::uuid, $3::uuid, $4::timestamptz, $5::timestamptz,
        $6::timestamptz, $7, $8, 'ical', $9::timestamptz
      )
      ON CONFLICT (property_id, departing_event_id) DO UPDATE SET
        arriving_event_id = EXCLUDED.arriving_event_id,
        checkout_at = EXCLUDED.checkout_at,
        next_checkin_at = EXCLUDED.next_checkin_at,
        suggested_start_at = EXCLUDED.suggested_start_at,
        suggested_duration_hours = EXCLUDED.suggested_duration_hours,
        status = EXCLUDED.status,
        updated_at = EXCLUDED.updated_at
      """,
           [
             feed["property_id"],
             departing_id,
             arriving_id,
             DateTime.to_iso8601(checkout_at),
             if(next_checkin_at, do: DateTime.to_iso8601(next_checkin_at), else: nil),
             DateTime.to_iso8601(suggestion.start_at),
             suggestion.duration_hours,
             suggestion.status,
             now
           ]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp cancel_stale_opportunities(feed, active_rows, now) do
    active_departing = MapSet.new(Enum.map(active_rows, fn [id | _] -> id end))

    case Repo.query(
           """
           SELECT id, departing_event_id, booking_id
           FROM public.turnover_opportunities
           WHERE property_id = $1::uuid AND status IN ('needs_review', 'ready_to_book', 'conflict')
           """,
           [feed["property_id"]]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.reduce_while(rows, :ok, fn [id, departing_event_id, booking_id], :ok ->
          if booking_id == nil and not MapSet.member?(active_departing, departing_event_id) do
            case Repo.query(
                   "UPDATE public.turnover_opportunities SET status = 'cancelled', updated_at = $2::timestamptz WHERE id = $1::uuid",
                   [id, now]
                 ) do
              {:ok, _} -> {:cont, :ok}
              {:error, error} -> {:halt, {:error, error}}
            end
          else
            {:cont, :ok}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  defp compute_suggested(checkout_at, next_checkin_at, minimum_minutes) do
    start_at = DateTime.add(checkout_at, @entry_buffer_minutes, :minute)
    min_hours = minimum_minutes / 60

    if is_nil(next_checkin_at) do
      %{start_at: start_at, duration_hours: clamp_hours(min_hours), status: "needs_review"}
    else
      deadline = DateTime.add(next_checkin_at, -@guest_ready_buffer_minutes, :minute)
      window_hours = DateTime.diff(deadline, start_at, :second) / 3600.0

      if window_hours < min_hours do
        %{
          start_at: start_at,
          duration_hours: max(0, Float.round(window_hours, 1)),
          status: "conflict"
        }
      else
        window_cap = Float.floor(window_hours * 2) / 2
        duration = clamp_hours(min_hours, min(3, window_cap))
        %{start_at: start_at, duration_hours: max(min_hours, duration), status: "needs_review"}
      end
    end
  end

  defp clamp_hours(min_hours, cap \\ nil) do
    hours = max(3, min_hours)
    hours = min(hours, 8)
    if cap, do: min(hours, cap), else: hours
  end

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_dt(%DateTime{} = dt), do: dt
  defp parse_dt(_), do: DateTime.utc_now()

  defp parse_ms(value), do: DateTime.to_unix(parse_dt(value), :millisecond)
end
