defmodule Mithril.Notifications.Reminders do
  @moduledoc """
  Visit reminders for Direct concierge bookings.

  An hourly Oban cron sweep finds due stages and enqueues unique send jobs.
  Stamps on `public.bookings` keep Mithril and the legacy Instaclean cron
  from double-sending the same stage.
  """

  require Logger

  alias Mithril.Notifications
  alias Mithril.Repo
  alias Mithril.Workers.BookingReminder

  @claim_ttl_minutes 45
  @hours_7d 24 * 7
  @hours_48 48
  @hours_24 24
  @tolerance_hours 1.0
  @morning_hour 8
  @morning_tolerance_hours 2.0
  @lookahead_days 8
  @batch_limit 200
  @terminal_statuses ~w(cancelled completed no_show)

  @stages ~w(customer_7d customer_48h customer_24h customer_morning cleaner)
  @columns %{
    "customer_7d" => {"customer_reminder_7d_claimed_at", "customer_reminder_7d_sent_at"},
    "customer_48h" => {"customer_reminder_48h_claimed_at", "customer_reminder_48h_sent_at"},
    "customer_24h" => {"customer_reminder_claimed_at", "customer_reminder_sent_at"},
    "customer_morning" =>
      {"customer_reminder_morning_claimed_at", "customer_reminder_morning_sent_at"},
    "cleaner" => {"cleaner_reminder_claimed_at", "cleaner_reminder_sent_at"}
  }

  def enqueue_due(now \\ DateTime.utc_now()) do
    jobs =
      now
      |> due_items()
      |> Enum.map(fn item ->
        BookingReminder.new(%{"booking_id" => item.booking_id, "stage" => item.stage})
      end)

    case jobs do
      [] ->
        {:ok, 0}

      jobs ->
        Oban.insert_all(jobs)
        {:ok, length(jobs)}
    end
  end

  def due_items(now \\ DateTime.utc_now()) do
    now_ms = DateTime.to_unix(now, :millisecond)
    claim_ttl_ms = @claim_ttl_minutes * 60 * 1000

    now
    |> candidate_rows()
    |> Enum.flat_map(fn row ->
      case row_scheduled_ms(row) do
        nil ->
          []

        scheduled_ms ->
          row
          |> enabled_stages()
          |> Enum.filter(fn stage ->
            stage_due?(row, stage, scheduled_ms, now_ms, claim_ttl_ms)
          end)
          |> Enum.map(fn stage ->
            %{booking_id: row.id, stage: stage, scheduled_ms: scheduled_ms}
          end)
      end
    end)
    |> Enum.sort_by(&stage_urgency(&1.stage))
    |> Enum.take(@batch_limit)
  end

  def send_stage(booking_id, stage) when stage in @stages do
    with {:ok, row} <- fetch_row(booking_id),
         true <- eligible?(row),
         {:ok, scheduled_ms} <- require_schedule(row),
         true <- still_due?(row, stage, scheduled_ms),
         :ok <- claim(booking_id, stage) do
      case deliver(row, stage) do
        true ->
          stamp_sent(booking_id, stage)
          :ok

        false ->
          release_claim(booking_id, stage)
          {:error, :undelivered}
      end
    else
      :already_claimed -> {:error, :already_claimed}
      _ -> :discard
    end
  end

  def send_stage(_booking_id, _stage), do: :discard

  def enabled_stages(row) do
    interval =
      row
      |> Map.get(:recurrence_interval)
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace("_", "-")

    cond do
      interval == "hourly" ->
        []

      interval == "daily" ->
        ["customer_24h", "cleaner"]

      interval in ~w(weekly bi-weekly monthly quarterly annually) ->
        ["customer_7d", "customer_48h", "customer_24h", "cleaner"]

      true ->
        ["customer_48h", "customer_24h", "customer_morning", "cleaner"]
    end
  end

  def in_window?(scheduled_ms, now_ms, target_hours, tolerance_hours \\ @tolerance_hours) do
    if scheduled_ms <= now_ms do
      false
    else
      hours_until = (scheduled_ms - now_ms) / 3_600_000
      half = max(0.25, tolerance_hours / 2)
      hours_until >= target_hours - half and hours_until <= target_hours + half
    end
  end

  def morning_of?(scheduled_date, scheduled_ms, now_ms, morning_hour \\ @morning_hour) do
    scheduled_ms > now_ms and accra_date(now_ms) == scheduled_date and
      in_morning_hour?(now_ms, morning_hour, @morning_tolerance_hours)
  end

  def scheduled_ms(date, time) do
    date_part = date_string(date)
    time_part = time_string(time)

    if date_part && time_part do
      case DateTime.from_iso8601("#{date_part}T#{time_part}Z") do
        {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
        _ -> nil
      end
    end
  end

  defp candidate_rows(now) do
    start_date = DateTime.to_date(now)
    end_date = Date.add(start_date, @lookahead_days)

    case Repo.query(
           """
           SELECT
             b.id::text,
             b.customer_id::text,
             b.cleaner_id::text,
             b.status,
             b.address,
             b.scheduled_date::text,
             b.scheduled_time::text,
             b.recurrence_interval,
             b.customer_reminder_7d_sent_at,
             b.customer_reminder_7d_claimed_at,
             b.customer_reminder_48h_sent_at,
             b.customer_reminder_48h_claimed_at,
             b.customer_reminder_sent_at,
             b.customer_reminder_claimed_at,
             b.customer_reminder_morning_sent_at,
             b.customer_reminder_morning_claimed_at,
             b.cleaner_reminder_sent_at,
             b.cleaner_reminder_claimed_at,
             (EXTRACT(EPOCH FROM (
               (b.scheduled_date + COALESCE(b.scheduled_time, TIME '00:00'))
               AT TIME ZONE tz.tz
             )) * 1000)::bigint,
             (now() AT TIME ZONE tz.tz)::date::text,
             EXTRACT(HOUR FROM (now() AT TIME ZONE tz.tz))::float
               + EXTRACT(MINUTE FROM (now() AT TIME ZONE tz.tz)) / 60.0
           FROM public.bookings b
           JOIN public.direct_booking_origins o ON o.booking_id = b.id
           CROSS JOIN LATERAL (
             SELECT COALESCE(
               NULLIF(btrim(to_jsonb(b)->>'timezone_name'), ''),
               NULLIF(btrim(to_jsonb(b)->>'timezone'), ''),
               'Africa/Accra'
             ) AS tz
           ) tz
           WHERE b.status <> ALL($3::text[])
             AND b.scheduled_date BETWEEN $1::date AND $2::date
           ORDER BY b.scheduled_date, b.scheduled_time
           LIMIT 500
           """,
           [start_date, end_date, @terminal_statuses]
         ) do
      {:ok, result} ->
        Enum.map(result.rows, &row_from_sql/1)

      {:error, error} ->
        Logger.error("Direct reminder candidate query failed: #{inspect(error)}")
        []
    end
  end

  defp fetch_row(booking_id) do
    with {:ok, uid} <- Ecto.UUID.dump(booking_id),
         {:ok, %{rows: [row]}} <-
           Repo.query(
             """
             SELECT
               b.id::text,
               b.customer_id::text,
               b.cleaner_id::text,
               b.status,
               b.address,
               b.scheduled_date::text,
               b.scheduled_time::text,
               b.recurrence_interval,
               b.customer_reminder_7d_sent_at,
               b.customer_reminder_7d_claimed_at,
               b.customer_reminder_48h_sent_at,
               b.customer_reminder_48h_claimed_at,
               b.customer_reminder_sent_at,
               b.customer_reminder_claimed_at,
               b.customer_reminder_morning_sent_at,
               b.customer_reminder_morning_claimed_at,
               b.cleaner_reminder_sent_at,
               b.cleaner_reminder_claimed_at,
               (EXTRACT(EPOCH FROM (
                 (b.scheduled_date + COALESCE(b.scheduled_time, TIME '00:00'))
                 AT TIME ZONE tz.tz
               )) * 1000)::bigint,
               (now() AT TIME ZONE tz.tz)::date::text,
               EXTRACT(HOUR FROM (now() AT TIME ZONE tz.tz))::float
                 + EXTRACT(MINUTE FROM (now() AT TIME ZONE tz.tz)) / 60.0
             FROM public.bookings b
             JOIN public.direct_booking_origins o ON o.booking_id = b.id
             CROSS JOIN LATERAL (
               SELECT COALESCE(
                 NULLIF(btrim(to_jsonb(b)->>'timezone_name'), ''),
                 NULLIF(btrim(to_jsonb(b)->>'timezone'), ''),
                 'Africa/Accra'
               ) AS tz
             ) tz
             WHERE b.id = $1
             LIMIT 1
             """,
             [uid]
           ) do
      {:ok, row_from_sql(row)}
    else
      _ -> :error
    end
  end

  defp row_from_sql([
         id,
         customer_id,
         cleaner_id,
         status,
         address,
         scheduled_date,
         scheduled_time,
         recurrence_interval,
         reminder_7d_sent,
         reminder_7d_claimed,
         reminder_48h_sent,
         reminder_48h_claimed,
         reminder_24h_sent,
         reminder_24h_claimed,
         reminder_morning_sent,
         reminder_morning_claimed,
         cleaner_sent,
         cleaner_claimed,
         scheduled_ms,
         local_today,
         local_hour
       ]) do
    %{
      id: id,
      customer_id: present(customer_id),
      cleaner_id: present(cleaner_id),
      status: to_string(status || ""),
      address: address,
      scheduled_date: scheduled_date,
      scheduled_time: scheduled_time,
      recurrence_interval: recurrence_interval,
      customer_reminder_7d_sent_at: reminder_7d_sent,
      customer_reminder_7d_claimed_at: reminder_7d_claimed,
      customer_reminder_48h_sent_at: reminder_48h_sent,
      customer_reminder_48h_claimed_at: reminder_48h_claimed,
      customer_reminder_sent_at: reminder_24h_sent,
      customer_reminder_claimed_at: reminder_24h_claimed,
      customer_reminder_morning_sent_at: reminder_morning_sent,
      customer_reminder_morning_claimed_at: reminder_morning_claimed,
      cleaner_reminder_sent_at: cleaner_sent,
      cleaner_reminder_claimed_at: cleaner_claimed,
      scheduled_ms: to_ms(scheduled_ms),
      local_today: present(local_today),
      local_hour: to_hour(local_hour)
    }
  end

  defp eligible?(row), do: row.status not in @terminal_statuses

  defp row_scheduled_ms(row) do
    row.scheduled_ms || scheduled_ms(row.scheduled_date, row.scheduled_time)
  end

  defp require_schedule(row) do
    case row_scheduled_ms(row) do
      nil -> :error
      ms -> {:ok, ms}
    end
  end

  defp still_due?(row, stage, scheduled_ms) do
    now_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)
    stage_due?(row, stage, scheduled_ms, now_ms, @claim_ttl_minutes * 60 * 1000)
  end

  defp stage_due?(row, stage, scheduled_ms, now_ms, claim_ttl_ms) do
    cond do
      stage not in enabled_stages(row) ->
        false

      stage == "cleaner" and is_nil(row.cleaner_id) ->
        false

      stage_sent_at(row, stage) != nil ->
        false

      claim_active?(stage_claimed_at(row, stage), now_ms, claim_ttl_ms) ->
        false

      stage == "customer_morning" ->
        morning_due?(row, scheduled_ms, now_ms)

      stage == "customer_7d" ->
        in_window?(scheduled_ms, now_ms, @hours_7d)

      stage == "customer_48h" ->
        in_window?(scheduled_ms, now_ms, @hours_48)

      stage in ["customer_24h", "cleaner"] ->
        in_window?(scheduled_ms, now_ms, @hours_24)

      true ->
        false
    end
  end

  defp stage_sent_at(row, "customer_7d"), do: row.customer_reminder_7d_sent_at
  defp stage_sent_at(row, "customer_48h"), do: row.customer_reminder_48h_sent_at
  defp stage_sent_at(row, "customer_24h"), do: row.customer_reminder_sent_at
  defp stage_sent_at(row, "customer_morning"), do: row.customer_reminder_morning_sent_at
  defp stage_sent_at(row, "cleaner"), do: row.cleaner_reminder_sent_at

  defp stage_claimed_at(row, "customer_7d"), do: row.customer_reminder_7d_claimed_at
  defp stage_claimed_at(row, "customer_48h"), do: row.customer_reminder_48h_claimed_at
  defp stage_claimed_at(row, "customer_24h"), do: row.customer_reminder_claimed_at
  defp stage_claimed_at(row, "customer_morning"), do: row.customer_reminder_morning_claimed_at
  defp stage_claimed_at(row, "cleaner"), do: row.cleaner_reminder_claimed_at

  defp claim_active?(nil, _now_ms, _ttl), do: false

  defp claim_active?(%DateTime{} = claimed_at, now_ms, ttl) do
    claimed_ms = DateTime.to_unix(claimed_at, :millisecond)
    now_ms - claimed_ms < ttl
  end

  defp claim_active?(claimed_at, now_ms, ttl) when is_binary(claimed_at) do
    case DateTime.from_iso8601(claimed_at) do
      {:ok, datetime, _} -> claim_active?(datetime, now_ms, ttl)
      _ -> false
    end
  end

  defp claim_active?(_, _, _), do: false

  defp claim(booking_id, stage) do
    {claimed_col, sent_col} = Map.fetch!(@columns, stage)

    with {:ok, uid} <- Ecto.UUID.dump(booking_id),
         {:ok, %{rows: [_id]}} <-
           Repo.query(
             """
             UPDATE public.bookings
             SET #{claimed_col} = now(),
                 customer_reminder_last_error = NULL
             WHERE id = $1
               AND #{sent_col} IS NULL
               AND (
                 #{claimed_col} IS NULL
                 OR #{claimed_col} < now() - ($2::integer * interval '1 minute')
               )
             RETURNING id::text
             """,
             [uid, @claim_ttl_minutes]
           ) do
      :ok
    else
      {:ok, %{rows: []}} ->
        :already_claimed

      {:error, error} ->
        Logger.warning("Direct reminder claim failed: #{inspect(error)}")
        :already_claimed
    end
  end

  defp stamp_sent(booking_id, stage) do
    {_claimed_col, sent_col} = Map.fetch!(@columns, stage)

    with {:ok, uid} <- Ecto.UUID.dump(booking_id) do
      Repo.query(
        """
        UPDATE public.bookings
        SET #{sent_col} = now()
        WHERE id = $1 AND #{sent_col} IS NULL
        """,
        [uid]
      )
    end
  end

  defp release_claim(booking_id, stage) do
    {claimed_col, sent_col} = Map.fetch!(@columns, stage)

    with {:ok, uid} <- Ecto.UUID.dump(booking_id) do
      Repo.query(
        """
        UPDATE public.bookings
        SET #{claimed_col} = NULL
        WHERE id = $1 AND #{sent_col} IS NULL
        """,
        [uid]
      )
    end
  end

  defp deliver(row, stage) do
    recipient = if stage == "cleaner", do: :worker, else: :customer

    Notifications.notify(%{
      send_notifications: true,
      kind: :booking_reminder,
      recipient: recipient,
      stage: stage,
      booking_id: row.id,
      customer: Notifications.load_party(row.customer_id),
      worker: Notifications.load_party(row.cleaner_id),
      dates: [row.scheduled_date],
      scheduled_time: row.scheduled_time,
      address: row.address
    })
  end

  defp stage_urgency("customer_morning"), do: 0
  defp stage_urgency("customer_24h"), do: 1
  defp stage_urgency("cleaner"), do: 1
  defp stage_urgency("customer_48h"), do: 2
  defp stage_urgency("customer_7d"), do: 3
  defp stage_urgency(_), do: 9

  defp accra_date(now_ms) do
    now_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp morning_due?(row, scheduled_ms, now_ms) do
    if is_binary(row.local_today) and is_number(row.local_hour) do
      scheduled_ms > now_ms and row.local_today == date_string(row.scheduled_date) and
        in_morning_hour_fraction?(row.local_hour, @morning_hour, @morning_tolerance_hours)
    else
      morning_of?(row.scheduled_date, scheduled_ms, now_ms)
    end
  end

  defp in_morning_hour?(now_ms, morning_hour, tolerance_hours) do
    datetime = DateTime.from_unix!(now_ms, :millisecond)
    hour_fractional = datetime.hour + datetime.minute / 60
    in_morning_hour_fraction?(hour_fractional, morning_hour, tolerance_hours)
  end

  defp in_morning_hour_fraction?(hour_fractional, morning_hour, tolerance_hours) do
    half = max(0.25, tolerance_hours / 2)
    hour_fractional >= morning_hour - half and hour_fractional <= morning_hour + half
  end

  defp to_ms(nil), do: nil
  defp to_ms(value) when is_integer(value), do: value
  defp to_ms(value) when is_float(value), do: round(value)
  defp to_ms(%Decimal{} = value), do: Decimal.to_integer(Decimal.round(value, 0))
  defp to_ms(_), do: nil

  defp to_hour(nil), do: nil
  defp to_hour(value) when is_number(value), do: value * 1.0
  defp to_hour(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_hour(_), do: nil

  defp date_string(%Date{} = date), do: Date.to_iso8601(date)
  defp date_string(value) when is_binary(value), do: String.trim(value)
  defp date_string(_), do: nil

  defp time_string(%Time{} = time), do: Calendar.strftime(time, "%H:%M:%S")

  defp time_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      Regex.match?(~r/^\d{1,2}:\d{2}:\d{2}/, value) -> String.slice(value, 0, 8)
      Regex.match?(~r/^\d{1,2}:\d{2}$/, value) -> value <> ":00"
      true -> "09:00:00"
    end
  end

  defp time_string(_), do: "09:00:00"

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(_), do: nil
end
