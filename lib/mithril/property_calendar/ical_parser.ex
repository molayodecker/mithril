defmodule Mithril.PropertyCalendar.IcalParser do
  @moduledoc false

  @max_events 5000

  @spec parse_events(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def parse_events(ics_text) when is_binary(ics_text) do
    if String.contains?(ics_text, "BEGIN:VCALENDAR") do
      lines = unfold_lines(ics_text)
      events = parse_vevents(lines)

      if length(events) > @max_events do
        {:error, "Calendar exceeds maximum event count (#{@max_events})"}
      else
        {:ok, events}
      end
    else
      {:error, "Invalid calendar format"}
    end
  end

  defp unfold_lines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      if String.starts_with?(line, [" ", "\t"]) and acc != [] do
        [hd | tail] = acc
        [hd <> String.trim_leading(line) | tail]
      else
        [line | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp parse_vevents(lines) do
    {events, _} =
      Enum.reduce(lines, {[], nil}, fn
        "BEGIN:VEVENT", {events, _} ->
          {events, %{}}

        "END:VEVENT", {events, current} when is_map(current) ->
          case finalize_event(current) do
            nil -> {events, nil}
            event -> {events ++ [event], nil}
          end

        line, {events, current} when is_map(current) ->
          {events, parse_line(current, line)}

        _line, acc ->
          acc
      end)

    events
  end

  defp parse_line(state, line) do
    case String.split(line, ":", parts: 2) do
      [left, value] ->
        key = left |> String.split(";") |> hd() |> String.upcase()

        Map.update(state, :raw, "#{key}=#{value}", &"#{&1}|#{key}=#{value}")
        |> put_field(key, value, left)

      _ ->
        state
    end
  end

  defp put_field(state, "UID", value, _), do: Map.put(state, :uid, String.trim(value))
  defp put_field(state, "SEQUENCE", value, _), do: Map.put(state, :sequence, parse_int(value))
  defp put_field(state, "SUMMARY", value, _), do: Map.put(state, :summary, String.trim(value))
  defp put_field(state, "STATUS", value, _), do: Map.put(state, :status, String.trim(value))
  defp put_field(state, "DTSTART", value, left), do: Map.put(state, :dtstart, {value, left})
  defp put_field(state, "DTEND", value, left), do: Map.put(state, :dtend, {value, left})
  defp put_field(state, _, _, _), do: state

  defp finalize_event(
         %{uid: uid, dtstart: {start_value, start_params}, dtend: {end_value, end_params}} = event
       )
       when is_binary(uid) do
    %{
      uid: uid,
      sequence: Map.get(event, :sequence),
      summary: Map.get(event, :summary),
      status: classify_status(Map.get(event, :summary), Map.get(event, :status)),
      dtstart: parse_date_value(start_value, start_params),
      dtend: parse_date_value(end_value, end_params),
      raw_hash_input: Map.get(event, :raw, "")
    }
  end

  defp finalize_event(_), do: nil

  defp classify_status(summary, ical_status) do
    cond do
      is_binary(ical_status) and String.match?(ical_status, ~r/cancelled/i) ->
        "cancelled"

      is_binary(summary) and
          String.match?(String.downcase(summary), ~r/blocked|not available|unavailable|closed/) ->
        "blocked"

      is_binary(summary) and
          String.match?(String.downcase(summary), ~r/reserved|airbnb|booking|guest/) ->
        "confirmed"

      true ->
        "unknown"
    end
  end

  defp parse_date_value(value, params) do
    trimmed = String.trim(value)
    date_only = String.contains?(params, "VALUE=DATE") or Regex.match?(~r/^\d{8}$/, trimmed)

    if date_only do
      %{kind: "date", date_part: String.slice(trimmed, 0, 8), time_part: nil}
    else
      case Regex.run(~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z)?$/, trimmed) do
        [_, y, m, d, hh, mm, ss, z] ->
          %{
            kind: if(z == "Z", do: "utc", else: "local"),
            date_part: "#{y}#{m}#{d}",
            time_part: "#{hh}#{mm}#{ss}"
          }

        _ ->
          nil
      end
    end
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _} -> integer
      :error -> nil
    end
  end
end
