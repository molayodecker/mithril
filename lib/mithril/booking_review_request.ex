defmodule Mithril.BookingReviewRequest do
  @moduledoc false

  @default_delay_hours 2.0

  @spec parse_delay_hours(term()) :: float()
  def parse_delay_hours(raw) do
    case raw do
      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {hours, _} when hours >= 0 -> hours
          _ -> @default_delay_hours
        end

      value when is_number(value) and value >= 0 ->
        value * 1.0

      _ ->
        @default_delay_hours
    end
  end

  @spec due?(DateTime.t() | nil, integer(), float()) :: boolean()
  def due?(completed_at, now_ms, delay_hours) do
    case completed_at do
      %DateTime{} = completed ->
        completed_ms = DateTime.to_unix(completed, :millisecond)
        delay_ms = trunc(max(0, delay_hours) * 3_600_000)
        completed_ms + delay_ms <= now_ms

      _ ->
        false
    end
  end

  @spec build_url(String.t(), String.t()) :: String.t()
  def build_url(app_url, token_or_booking_id) do
    base =
      app_url
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    base = if base == "", do: "https://tryinstaclean.com", else: base

    value = token_or_booking_id |> to_string() |> String.trim()

    if value == "" do
      "#{base}/review"
    else
      "#{base}/review/#{URI.encode(value)}"
    end
  end

  @spec filter_pending(list(), MapSet.t()) :: list()
  def filter_pending(bookings, reviewed_ids) when is_list(bookings) do
    Enum.reject(bookings, fn row ->
      id = row_id(row)
      id != nil and MapSet.member?(reviewed_ids, id)
    end)
  end

  @spec reviewed_booking_ids(list(), list()) :: MapSet.t()
  def reviewed_booking_ids(bookings, reviews) when is_list(bookings) and is_list(reviews) do
    customer_by_booking =
      Map.new(bookings, fn row ->
        {row_id(row), row_customer_id(row)}
      end)

    reviews
    |> Enum.reduce(MapSet.new(), fn review, acc ->
      booking_id = review_booking_id(review)
      reviewer_id = review_reviewer_id(review)

      if booking_id != nil and reviewer_id != nil and
           Map.get(customer_by_booking, booking_id) == reviewer_id do
        MapSet.put(acc, booking_id)
      else
        acc
      end
    end)
  end

  @spec active_delivered?(map()) :: boolean()
  def active_delivered?(result) when is_map(result) do
    truthy?(Map.get(result, :email_sent) || Map.get(result, "emailSent")) or
      truthy?(Map.get(result, :sms_sent) || Map.get(result, "smsSent")) or
      truthy?(Map.get(result, :whatsapp_sent) || Map.get(result, "whatsappSent")) or
      push_count(result) > 0
  end

  defp push_count(result) do
    case Map.get(result, :push_sent) || Map.get(result, "pushSent") do
      count when is_integer(count) and count > 0 -> count
      _ -> 0
    end
  end

  defp row_id(%{"id" => id}), do: to_string(id)
  defp row_id(%{id: id}), do: to_string(id)
  defp row_id(_), do: nil

  defp row_customer_id(%{"customer_id" => id}), do: to_string(id)
  defp row_customer_id(%{customer_id: id}), do: to_string(id)
  defp row_customer_id(_), do: nil

  defp review_booking_id(%{"booking_id" => id}) when not is_nil(id), do: to_string(id)
  defp review_booking_id(%{booking_id: id}) when not is_nil(id), do: to_string(id)
  defp review_booking_id(_), do: nil

  defp review_reviewer_id(%{"reviewer_id" => id}) when not is_nil(id), do: to_string(id)
  defp review_reviewer_id(%{reviewer_id: id}) when not is_nil(id), do: to_string(id)
  defp review_reviewer_id(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
