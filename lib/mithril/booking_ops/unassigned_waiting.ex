defmodule Mithril.BookingOps.UnassignedWaiting do
  @moduledoc false

  @type row :: map()

  @spec notice_due?(row(), pos_integer(), integer()) :: boolean()
  def notice_due?(row, waiting_minutes, now_ms \\ System.system_time(:millisecond)) do
    case parse_ms(Map.get(row, "ops_unassigned_paid_notice_sent_at")) do
      nil ->
        ops_due?(row, waiting_minutes, now_ms)

      last_sent_ms ->
        last_sent_ms <= now_ms - waiting_minutes * 60_000
    end
  end

  @spec repeat_notice?(row()) :: boolean()
  def repeat_notice?(row) do
    parse_ms(Map.get(row, "ops_unassigned_paid_notice_sent_at")) != nil
  end

  @spec sort_key_ms(row()) :: integer()
  def sort_key_ms(row) do
    parse_ms(Map.get(row, "ops_unassigned_paid_notice_sent_at")) ||
      waiting_since_ms(row) ||
      9_007_199_254_740_991
  end

  defp ops_due?(row, waiting_minutes, now_ms) do
    case waiting_since_ms(row, now_ms) do
      nil -> false
      waiting_since_ms -> waiting_since_ms <= now_ms - waiting_minutes * 60_000
    end
  end

  defp waiting_since_ms(row, now_ms \\ System.system_time(:millisecond)) do
    phase = row |> Map.get("assignment_phase", "") |> to_string() |> String.trim()
    hold_end_ms = parse_ms(Map.get(row, "assignment_hold_until"))

    cond do
      phase == "exclusive" and hold_end_ms != nil and hold_end_ms > now_ms ->
        nil

      phase == "exclusive" and hold_end_ms != nil ->
        hold_end_ms

      parse_ms(Map.get(row, "dispatch_gated_at")) != nil and
          parse_ms(Map.get(row, "dispatch_gate_cleared_at")) == nil ->
        parse_ms(Map.get(row, "dispatch_gated_at"))

      parse_ms(Map.get(row, "dispatch_gate_cleared_at")) != nil ->
        parse_ms(Map.get(row, "dispatch_gate_cleared_at"))

      hold_end_ms != nil and hold_end_ms <= now_ms ->
        hold_end_ms

      parse_ms(Map.get(row, "updated_at")) != nil ->
        parse_ms(Map.get(row, "updated_at"))

      true ->
        parse_ms(Map.get(row, "created_at"))
    end
  end

  defp parse_ms(nil), do: nil

  defp parse_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp parse_ms(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :millisecond)
  defp parse_ms(_), do: nil
end
