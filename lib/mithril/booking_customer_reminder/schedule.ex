defmodule Mithril.BookingCustomerReminder.Schedule do
  @moduledoc false

  @default_time "09:00:00"

  @type reminder_stage ::
          :customer_7d | :customer_48h | :customer_24h | :customer_morning | :cleaner

  @type row :: %{
          optional(String.t()) => term()
        }

  @spec normalize_scheduled_time(term()) :: String.t()
  def normalize_scheduled_time(raw) do
    scheduled = raw |> to_string() |> String.trim()

    cond do
      scheduled == "" ->
        @default_time

      Regex.match?(~r/^\d{1,2}:\d{2}$/, scheduled) ->
        "#{scheduled}:00"

      Regex.match?(~r/^\d{1,2}:\d{2}:\d{2}$/, scheduled) ->
        scheduled

      true ->
        case Regex.run(~r/^(\d{1,2}:\d{2})/, scheduled) do
          [_, time] -> "#{time}:00"
          _ -> @default_time
        end
    end
  end

  @spec parse_scheduled_ms(term(), term()) :: integer() | nil
  def parse_scheduled_ms(scheduled_date, scheduled_time) do
    date_part = scheduled_date |> to_string() |> String.trim()

    if date_part == "" do
      nil
    else
      time_part = normalize_scheduled_time(scheduled_time)
      iso = "#{date_part}T#{time_part}Z"

      case DateTime.from_iso8601(iso) do
        {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
        _ -> nil
      end
    end
  end

  @spec in_reminder_window?(integer(), integer(), number(), number()) :: boolean()
  def in_reminder_window?(scheduled_ms, now_ms, target_hours_before, tolerance_hours)
      when is_integer(scheduled_ms) and is_integer(now_ms) do
    if scheduled_ms <= now_ms do
      false
    else
      hours_until = (scheduled_ms - now_ms) / 3_600_000
      half = max(0.25, tolerance_hours / 2)
      min_hours = target_hours_before - half
      max_hours = target_hours_before + half
      hours_until >= min_hours and hours_until <= max_hours
    end
  end

  @spec in_morning_window?(term(), integer(), integer(), integer(), number()) :: boolean()
  def in_morning_window?(scheduled_date, scheduled_ms, now_ms, morning_hour, tolerance_hours)
      when is_integer(scheduled_ms) and is_integer(now_ms) do
    if scheduled_ms <= now_ms do
      false
    else
      date_part = scheduled_date |> to_string() |> String.trim()

      if date_part == "" or accra_date_string(now_ms) != date_part do
        false
      else
        {:ok, now_dt} = DateTime.from_unix(now_ms, :millisecond)
        hour_fractional = now_dt.hour + now_dt.minute / 60
        half = max(0.25, tolerance_hours / 2)
        hour_fractional >= morning_hour - half and hour_fractional <= morning_hour + half
      end
    end
  end

  @spec format_scheduled_combined(term(), term()) :: String.t()
  def format_scheduled_combined(scheduled_date, scheduled_time) do
    date = scheduled_date |> to_string() |> String.trim()
    time = normalize_scheduled_time(scheduled_time) |> String.slice(0, 5)

    cond do
      date != "" and time != "" -> "#{date} #{time}"
      date != "" -> date
      true -> time
    end
  end

  @spec accra_date_string(integer()) :: String.t()
  def accra_date_string(now_ms) when is_integer(now_ms) do
    # Edge uses Intl timeZone Africa/Accra (UTC+0, no DST). Avoid tzdata in Mithril.
    {:ok, dt} = DateTime.from_unix(now_ms, :millisecond)
    DateTime.to_date(dt) |> Date.to_iso8601()
  end

  @spec add_days_to_date_string(String.t(), integer()) :: String.t()
  def add_days_to_date_string(date_str, days) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> Date.add(date, days) |> Date.to_iso8601()
      _ -> date_str
    end
  end

  @spec look_ahead_days(number(), number()) :: integer()
  def look_ahead_days(hours_horizon, tolerance_hours) do
    horizon = if is_number(hours_horizon), do: max(0, hours_horizon), else: 0
    tolerance = if is_number(tolerance_hours), do: max(0, tolerance_hours), else: 0
    trunc(Float.ceil((horizon + tolerance) / 24)) + 1
  end

  @spec notification_delivered?(map()) :: boolean()
  def notification_delivered?(result) when is_map(result) do
    truthy?(result[:email_sent] || result["emailSent"]) or
      truthy?(result[:sms_sent] || result["smsSent"]) or
      truthy?(result[:whatsapp_sent] || result["whatsappSent"]) or
      truthy?(result[:inbox_inserted] || result["inboxInserted"]) or
      push_count(result) > 0
  end

  @spec claim_kind(reminder_stage()) :: String.t()
  def claim_kind(:customer_7d), do: "customer_7d"
  def claim_kind(:customer_48h), do: "customer_48h"
  def claim_kind(:customer_24h), do: "customer"
  def claim_kind(:customer_morning), do: "customer_morning"
  def claim_kind(:cleaner), do: "cleaner"

  @spec stage_label(reminder_stage()) :: String.t()
  def stage_label(:customer_7d), do: "7d"
  def stage_label(:customer_48h), do: "48h"
  def stage_label(:customer_24h), do: "24h"
  def stage_label(:customer_morning), do: "morning"
  def stage_label(:cleaner), do: "cleaner"

  @spec eligible_row?(row(), MapSet.t() | nil) :: boolean()
  def eligible_row?(row, open_schedule_group_ids) do
    status = field(row, "status") |> to_string()
    subscription_id = field(row, "subscription_id") |> to_string() |> String.trim()
    is_subscription_placeholder = subscription_id != ""

    status_ok =
      status in ["confirmed", "scheduled"] or
        (status == "pending" and is_subscription_placeholder)

    unless status_ok,
      do: false,
      else: payment_eligible(row, open_schedule_group_ids, is_subscription_placeholder)
  end

  defp payment_eligible(row, open_schedule_group_ids, is_subscription_placeholder) do
    payment_status = field(row, "payment_status") |> to_string() |> String.downcase()

    cond do
      payment_status == "paid" ->
        true

      is_subscription_placeholder and payment_status in ["pending", "post_paid"] ->
        true

      payment_status not in ["pending", "post_paid"] ->
        false

      field(row, "schedule_group_id") in [nil, ""] ->
        false

      open_schedule_group_ids != nil and
          MapSet.member?(open_schedule_group_ids, to_string(field(row, "schedule_group_id"))) ->
        true

      true ->
        closed_group_finish?(row)
    end
  end

  defp closed_group_finish?(row) do
    customer_sequence_started =
      sent?(row, "customer_reminder_7d_sent_at") or sent?(row, "customer_reminder_48h_sent_at") or
        sent?(row, "customer_reminder_sent_at") or sent?(row, "customer_reminder_morning_sent_at")

    if not customer_sequence_started do
      false
    else
      enabled = enabled_stages(field(row, "recurrence_interval"))

      unfinished_customer =
        Enum.any?(enabled, fn stage ->
          stage != :cleaner and stage_needs_attempt?(row, stage, 0, 0)
        end)

      unfinished_cleaner =
        field(row, "cleaner_id") not in [nil, ""] and not sent?(row, "cleaner_reminder_sent_at")

      unfinished_customer or unfinished_cleaner
    end
  end

  @spec enabled_stages(term()) :: [reminder_stage()]
  def enabled_stages(recurrence_interval) do
    interval = recurrence_interval |> to_string() |> String.trim() |> String.downcase()

    cond do
      interval == "hourly" ->
        []

      interval == "daily" ->
        [:customer_24h, :cleaner]

      interval in ["weekly", "bi-weekly", "monthly", "quarterly", "annually"] ->
        [:customer_7d, :customer_48h, :customer_24h, :cleaner]

      true ->
        [:customer_48h, :customer_24h, :customer_morning, :cleaner]
    end
  end

  @spec stage_needs_attempt?(row(), reminder_stage(), integer(), integer()) :: boolean()
  def stage_needs_attempt?(row, stage, now_ms, claim_ttl_ms) do
    if stage == :cleaner and field(row, "cleaner_id") in [nil, ""] do
      false
    else
      if sent?(row, sent_column(stage)) do
        false
      else
        not claim_active?(row, claim_column(stage), now_ms, claim_ttl_ms)
      end
    end
  end

  @spec select_due_work_items([row()], integer(), integer(), integer(), keyword()) :: [
          %{row: row(), stage: reminder_stage(), scheduled_ms: integer()}
        ]
  def select_due_work_items(candidates, now_ms, batch_limit, claim_ttl_ms, opts \\ []) do
    hours7d = Keyword.get(opts, :hours7d, 24 * 7)
    hours48 = Keyword.get(opts, :hours48, 48)
    hours24 = Keyword.get(opts, :hours24, 24)
    tolerance_hours = Keyword.get(opts, :tolerance_hours, 1)
    morning_hour = Keyword.get(opts, :morning_hour, 8)
    morning_tolerance = Keyword.get(opts, :morning_tolerance_hours, max(tolerance_hours, 2))

    items =
      Enum.flat_map(candidates, fn row ->
        case parse_scheduled_ms(field(row, "scheduled_date"), field(row, "scheduled_time")) do
          nil ->
            []

          scheduled_ms ->
            due_stages_for_row(row, scheduled_ms, now_ms, claim_ttl_ms, %{
              hours7d: hours7d,
              hours48: hours48,
              hours24: hours24,
              tolerance_hours: tolerance_hours,
              morning_hour: morning_hour,
              morning_tolerance_hours: morning_tolerance
            })
            |> Enum.map(fn stage ->
              %{row: row, stage: stage, scheduled_ms: scheduled_ms}
            end)
        end
      end)

    items
    |> Enum.sort_by(fn item -> {stage_urgency(item.stage), item.scheduled_ms} end)
    |> Enum.take(batch_limit)
  end

  defp due_stages_for_row(row, scheduled_ms, now_ms, claim_ttl_ms, opts) do
    enabled = MapSet.new(enabled_stages(field(row, "recurrence_interval")))
    stages = []

    stages =
      if MapSet.member?(enabled, :customer_7d) and
           stage_needs_attempt?(row, :customer_7d, now_ms, claim_ttl_ms) and
           in_reminder_window?(scheduled_ms, now_ms, opts[:hours7d], opts[:tolerance_hours]) do
        [:customer_7d | stages]
      else
        stages
      end

    stages =
      if MapSet.member?(enabled, :customer_48h) and
           stage_needs_attempt?(row, :customer_48h, now_ms, claim_ttl_ms) and
           in_reminder_window?(scheduled_ms, now_ms, opts[:hours48], opts[:tolerance_hours]) do
        [:customer_48h | stages]
      else
        stages
      end

    stages =
      if MapSet.member?(enabled, :customer_24h) and
           stage_needs_attempt?(row, :customer_24h, now_ms, claim_ttl_ms) and
           in_reminder_window?(scheduled_ms, now_ms, opts[:hours24], opts[:tolerance_hours]) do
        [:customer_24h | stages]
      else
        stages
      end

    stages =
      if MapSet.member?(enabled, :customer_morning) and
           stage_needs_attempt?(row, :customer_morning, now_ms, claim_ttl_ms) and
           in_morning_window?(
             field(row, "scheduled_date"),
             scheduled_ms,
             now_ms,
             opts[:morning_hour],
             opts[:morning_tolerance_hours]
           ) do
        [:customer_morning | stages]
      else
        stages
      end

    if MapSet.member?(enabled, :cleaner) and
         stage_needs_attempt?(row, :cleaner, now_ms, claim_ttl_ms) and
         in_reminder_window?(scheduled_ms, now_ms, opts[:hours24], opts[:tolerance_hours]) do
      [:cleaner | stages]
    else
      stages
    end
  end

  defp stage_urgency(:customer_morning), do: 0
  defp stage_urgency(:customer_24h), do: 1
  defp stage_urgency(:cleaner), do: 1
  defp stage_urgency(:customer_48h), do: 2
  defp stage_urgency(:customer_7d), do: 3

  defp claim_active?(row, column, now_ms, claim_ttl_ms) do
    case field(row, column) do
      nil ->
        false

      claimed_at when is_binary(claimed_at) ->
        case DateTime.from_iso8601(claimed_at) do
          {:ok, dt, _} ->
            claimed_ms = DateTime.to_unix(dt, :millisecond)
            now_ms - claimed_ms < claim_ttl_ms

          _ ->
            false
        end

      %DateTime{} = dt ->
        claimed_ms = DateTime.to_unix(dt, :millisecond)
        now_ms - claimed_ms < claim_ttl_ms

      _ ->
        false
    end
  end

  defp sent?(row, column), do: field(row, column) not in [nil, ""]

  defp sent_column(:customer_7d), do: "customer_reminder_7d_sent_at"
  defp sent_column(:customer_48h), do: "customer_reminder_48h_sent_at"
  defp sent_column(:customer_24h), do: "customer_reminder_sent_at"
  defp sent_column(:customer_morning), do: "customer_reminder_morning_sent_at"
  defp sent_column(:cleaner), do: "cleaner_reminder_sent_at"

  defp claim_column(:customer_7d), do: "customer_reminder_7d_claimed_at"
  defp claim_column(:customer_48h), do: "customer_reminder_48h_claimed_at"
  defp claim_column(:customer_24h), do: "customer_reminder_claimed_at"
  defp claim_column(:customer_morning), do: "customer_reminder_morning_claimed_at"
  defp claim_column(:cleaner), do: "cleaner_reminder_claimed_at"

  defp field(row, key) when is_map(row) do
    Map.get(row, key) || Map.get(row, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(row, key)
  end

  defp push_count(result) do
    case result[:push_sent] || result["pushSent"] do
      count when is_integer(count) and count > 0 -> count
      _ -> 0
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
