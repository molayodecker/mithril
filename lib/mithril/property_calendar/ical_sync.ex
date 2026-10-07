defmodule Mithril.PropertyCalendar.IcalSync do
  @moduledoc false

  alias Mithril.PropertyCalendar.{IcalParser, TurnoverOpportunities}
  alias Mithril.Repo

  @missing_threshold 3

  @doc false
  @spec apply_incoming_event?(map() | nil, integer() | nil, String.t() | nil) :: boolean()
  def apply_incoming_event?(existing, sequence, hash),
    do: apply_incoming?(existing, sequence, hash)

  @doc false
  @spec missing_sync_threshold() :: pos_integer()
  def missing_sync_threshold, do: @missing_threshold

  @doc false
  def resolve_window_for_test(event, feed), do: resolve_window(event, feed)

  @doc false
  @spec credible_after_parse?([map()], non_neg_integer()) :: :ok | {:error, String.t()}
  def credible_after_parse?(parsed_events, prior_active_count) do
    if parsed_events == [] and prior_active_count > 0 do
      {:error, "Feed returned zero events but property had prior imported events"}
    else
      :ok
    end
  end

  @spec import_feed(map(), String.t()) :: :ok | {:error, String.t()}
  def import_feed(feed, ics_text) do
    with {:ok, parsed} <- IcalParser.parse_events(ics_text),
         :ok <- credible_feed?(parsed, feed["id"]),
         :ok <- upsert_events(feed, parsed),
         :ok <- TurnoverOpportunities.recompute(feed) do
      :ok
    end
  end

  defp credible_feed?(parsed, feed_id) do
    case credible_after_parse?(parsed, prior_event_count(feed_id)) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp prior_event_count(feed_id) do
    case Repo.query(
           """
           SELECT count(*)::int FROM public.property_calendar_events
           WHERE calendar_feed_id = $1::uuid AND cancelled_at IS NULL
           """,
           [feed_id]
         ) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp upsert_events(feed, parsed) do
    now = DateTime.utc_now()

    existing =
      case Repo.query(
             """
             SELECT id, external_uid, external_sequence, raw_event_hash, missing_sync_count, status
             FROM public.property_calendar_events WHERE calendar_feed_id = $1::uuid
             """,
             [feed["id"]]
           ) do
        {:ok, %{rows: rows}} ->
          Map.new(rows, fn [id, uid, seq, hash, missing, status] ->
            {uid,
             %{
               id: id,
               sequence: seq,
               raw_event_hash: hash,
               missing_sync_count: missing,
               status: status
             }}
          end)

        _ ->
          %{}
      end

    with {:ok, seen_uids} <- persist_parsed_events(parsed, existing, feed, now) do
      reconcile_missing(existing, seen_uids, now, feed["id"])
      :ok
    end
  end

  defp persist_parsed_events(parsed, existing, feed, now) do
    Enum.reduce_while(parsed, {:ok, MapSet.new()}, fn event, {:ok, seen_acc} ->
      raw_hash = :crypto.hash(:sha256, event.raw_hash_input) |> Base.encode16(case: :lower)
      existing_row = Map.get(existing, event.uid)

      result =
        if apply_incoming?(existing_row, event.sequence, raw_hash) do
          persist_event(feed, event, raw_hash, now)
        else
          :ok
        end

      case result do
        :ok ->
          {:cont, {:ok, MapSet.put(seen_acc, event.uid)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp persist_event(feed, event, raw_hash, now) do
    {starts_at, ends_at} = resolve_window(event, feed)

    case Repo.query(
           """
           INSERT INTO public.property_calendar_events (
             calendar_feed_id, property_id, external_uid, external_sequence, status,
             starts_at, ends_at, summary, raw_event_hash, last_seen_at, missing_sync_count,
             cancelled_at, updated_at
           ) VALUES (
             $1::uuid, $2::uuid, $3, $4, $5,
             COALESCE($6::timestamptz, $12::timestamp AT TIME ZONE $14::text),
             COALESCE($7::timestamptz, $13::timestamp AT TIME ZONE $14::text),
             $8, $9, $10::timestamptz, 0, $11, $10::timestamptz
           )
           ON CONFLICT (calendar_feed_id, external_uid) DO UPDATE SET
             external_sequence = EXCLUDED.external_sequence,
             status = EXCLUDED.status,
             starts_at = EXCLUDED.starts_at,
             ends_at = EXCLUDED.ends_at,
             summary = EXCLUDED.summary,
             raw_event_hash = EXCLUDED.raw_event_hash,
             last_seen_at = EXCLUDED.last_seen_at,
             missing_sync_count = 0,
             cancelled_at = EXCLUDED.cancelled_at,
             updated_at = EXCLUDED.updated_at
           """,
           [
             feed["id"],
             feed["property_id"],
             event.uid,
             event.sequence,
             event.status,
             starts_at.utc,
             ends_at.utc,
             event.summary,
             raw_hash,
             now,
             if(event.status == "cancelled", do: now, else: nil),
             starts_at.local,
             ends_at.local,
             feed["timezone"] || "Africa/Accra"
           ]
         ) do
      {:ok, _} -> :ok
      {:error, _reason} -> {:error, "Failed to persist calendar event"}
    end
  end

  defp reconcile_missing(existing, seen_uids, now, _feed_id) do
    existing
    |> Enum.each(fn {uid, row} ->
      if MapSet.member?(seen_uids, uid) do
        :ok
      else
        next_missing = (row.missing_sync_count || 0) + 1

        if next_missing >= @missing_threshold do
          Repo.query(
            """
            UPDATE public.property_calendar_events
            SET status = 'cancelled', cancelled_at = $2::timestamptz,
                missing_sync_count = $3, updated_at = $2::timestamptz
            WHERE id = $1::uuid
            """,
            [row.id, now, next_missing]
          )
        else
          Repo.query(
            "UPDATE public.property_calendar_events SET missing_sync_count = $2, updated_at = $3::timestamptz WHERE id = $1::uuid",
            [row.id, next_missing, now]
          )
        end
      end
    end)
  end

  defp apply_incoming?(nil, _sequence, _hash), do: true

  defp apply_incoming?(existing, sequence, hash) do
    cond do
      is_integer(sequence) and is_integer(existing.sequence) and sequence < existing.sequence ->
        false

      is_nil(sequence) and existing.raw_event_hash == hash ->
        false

      true ->
        true
    end
  end

  defp resolve_window(event, feed) do
    checkin = feed["default_checkin_time"] || "15:00:00"
    checkout = feed["default_checkout_time"] || "11:00:00"

    starts_at = resolve_instant(event.dtstart, checkin)
    ends_at = resolve_instant(event.dtend, checkout)
    {starts_at, ends_at}
  end

  defp resolve_instant(%{kind: "date", date_part: date_part}, default_time) do
    %{utc: nil, local: parse_naive_datetime!(date_part, default_time)}
  end

  defp resolve_instant(%{kind: "utc", date_part: date_part, time_part: time_part}, _default) do
    {:ok, datetime, 0} =
      DateTime.from_iso8601("#{format_date(date_part)}T#{format_time(time_part)}Z")

    %{utc: datetime, local: nil}
  end

  defp resolve_instant(%{kind: "local", date_part: date_part, time_part: time_part}, _default) do
    %{utc: nil, local: parse_naive_datetime!(date_part, format_time(time_part))}
  end

  defp resolve_instant(_, default_time) do
    %{utc: nil, local: parse_naive_datetime!("19700101", default_time)}
  end

  defp parse_naive_datetime!(date_part, time) do
    {:ok, datetime} = NaiveDateTime.from_iso8601("#{format_date(date_part)}T#{time}")
    datetime
  end

  defp format_date(yyyymmdd) do
    <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>> = yyyymmdd
    "#{y}-#{m}-#{d}"
  end

  defp format_time(hhmmss) when is_binary(hhmmss) do
    <<hh::binary-size(2), mm::binary-size(2), ss::binary-size(2)>> =
      String.pad_leading(hhmmss, 6, "0")

    "#{hh}:#{mm}:#{ss}"
  end

  defp format_time(_), do: "00:00:00"
end
