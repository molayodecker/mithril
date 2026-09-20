defmodule Mithril.DirectCancellation do
  @moduledoc """
  Customer cancellation policy for Direct.

  Mirrors Instaclean marketplace `cancellationPolicy.ts`: pending / confirmed /
  scheduled bookings may be cancelled. Paid bookings get a full refund when the
  visit is at least 24 hours away, 50% inside that window, and no refund on the
  calendar day of the visit or after it has started.
  """

  @window_hours 24
  @cancellable_statuses ~w(pending confirmed scheduled)

  @refund_timeline "Most refunds arrive within 16–48 hours. Depending on your payment method (card, mobile money, or bank transfer) and your bank or mobile-money provider, some refunds may take 3–10 business days."

  def cancellable_statuses, do: @cancellable_statuses

  def evaluate(input, now \\ DateTime.utc_now()) when is_map(input) do
    status = to_string_or_nil(Map.get(input, :status) || Map.get(input, "status"))

    payment_status =
      to_string_or_nil(Map.get(input, :payment_status) || Map.get(input, "payment_status"))

    scheduled_date = Map.get(input, :scheduled_date) || Map.get(input, "scheduled_date")
    scheduled_at = Map.get(input, :scheduled_at) || Map.get(input, "scheduled_at")
    local_today = Map.get(input, :local_today) || Map.get(input, "local_today")
    amount_minor = amount_minor(input)
    is_paid = payment_status == "paid"

    if status in @cancellable_statuses do
      tier = refund_tier(scheduled_date, scheduled_at, local_today, now)
      refund_percent = refund_percent(is_paid, tier)
      refund_amount_minor = refund_amount(amount_minor, refund_percent)

      %{
        tier: tier,
        can_cancel: true,
        refund_percent: refund_percent,
        refund_amount_minor: refund_amount_minor,
        is_paid: is_paid,
        success_message: success_message(is_paid, tier, refund_percent, refund_amount_minor),
        error_message: nil
      }
    else
      %{
        tier: "not_cancellable",
        can_cancel: false,
        refund_percent: 0,
        refund_amount_minor: 0,
        is_paid: is_paid,
        success_message: "",
        error_message: not_cancellable_message(status)
      }
    end
  end

  def existing_refund_success_message(params) when is_map(params) do
    tier = params.tier
    refund_status = params.refund_status
    refund_percent = params.refund_percent
    refund_amount_minor = params.refund_amount_minor

    cond do
      refund_status == "manual_review" ->
        "Your booking has been cancelled. Our team will process your refund manually."

      refund_status == "failed" ->
        "Your booking has been cancelled. We could not process your refund automatically — our team will follow up."

      tier == "no_refund" or refund_percent == 0 ->
        "Your booking has been cancelled. No refund applies."

      refund_status == "processed" ->
        "Your booking has been cancelled. Your refund of #{format_cedis(refund_amount_minor)} has been processed. #{@refund_timeline}"

      refund_status == "pending" ->
        "Your booking has been cancelled. Your refund of #{format_cedis(refund_amount_minor)} is being processed. #{@refund_timeline}"

      true ->
        "Your booking has been cancelled. Your refund of #{format_cedis(refund_amount_minor)} is #{refund_status}."
    end
  end

  def success_message_for_refund(tier, refund_status, policy_message) do
    cond do
      refund_status == "manual_review" ->
        "Your booking has been cancelled. Our team will process your refund manually."

      refund_status == "failed" ->
        "Your booking has been cancelled. We could not process your refund automatically — our team will follow up."

      tier == "no_refund" ->
        "Your booking has been cancelled. No refund applies."

      is_binary(policy_message) and policy_message != "" ->
        policy_message

      true ->
        "Your booking has been cancelled."
    end
  end

  def payment_status_after_refund(100), do: "refunded"
  def payment_status_after_refund(50), do: "partially_refunded"
  def payment_status_after_refund(_), do: nil

  defp refund_tier(scheduled_date, scheduled_at, local_today, now) do
    scheduled_at = datetime(scheduled_at)
    now = datetime(now)

    cond do
      same_calendar_day?(scheduled_date, local_today) ->
        "no_refund"

      match?(%DateTime{}, scheduled_at) and DateTime.compare(scheduled_at, now) != :gt ->
        "no_refund"

      is_nil(scheduled_at) ->
        "full_refund"

      DateTime.diff(scheduled_at, now, :second) / 3_600 >= @window_hours ->
        "full_refund"

      true ->
        "partial_refund"
    end
  end

  defp refund_percent(true, "full_refund"), do: 100
  defp refund_percent(true, "partial_refund"), do: 50
  defp refund_percent(_, _), do: 0

  defp refund_amount(_amount, 0), do: 0
  defp refund_amount(amount_minor, percent), do: round(amount_minor * percent / 100)

  defp success_message(_is_paid, "no_refund", _percent, _amount) do
    "Your booking has been cancelled. No refund applies."
  end

  defp success_message(true, _tier, percent, amount_minor) when percent > 0 do
    "Your booking has been cancelled. #{refund_detail_message(percent, amount_minor)}"
  end

  defp success_message(_is_paid, _tier, _percent, _amount) do
    "Your booking has been cancelled."
  end

  defp refund_detail_message(100, amount_minor) do
    "You will receive a full refund of #{format_cedis(amount_minor)} to your original payment method. #{@refund_timeline}"
  end

  defp refund_detail_message(50, amount_minor) do
    "You will receive a 50% refund of #{format_cedis(amount_minor)} (50% cancellation fee). #{@refund_timeline}"
  end

  defp refund_detail_message(_percent, _amount), do: ""

  defp not_cancellable_message("cancelled"), do: "This booking has already been cancelled."
  defp not_cancellable_message("completed"), do: "Completed bookings cannot be cancelled."

  defp not_cancellable_message(status) when status in ~w(en_route arrived in_progress) do
    "Your cleaner is already on the way or the visit is in progress. Contact support if you need assistance."
  end

  defp not_cancellable_message(_),
    do: "This booking cannot be cancelled in the app. Contact support for help."

  defp same_calendar_day?(%Date{} = scheduled, %Date{} = today),
    do: Date.compare(scheduled, today) == :eq

  defp same_calendar_day?(_, _), do: false

  defp amount_minor(input) do
    value = Map.get(input, :amount_minor) || Map.get(input, "amount_minor") || 0
    amount_to_integer(value)
  end

  defp amount_to_integer(value) when is_integer(value), do: value
  defp amount_to_integer(%Decimal{} = value), do: Decimal.to_integer(Decimal.round(value, 0))

  defp amount_to_integer(value) when is_float(value), do: round(value)

  defp amount_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp amount_to_integer(_), do: 0

  defp datetime(%DateTime{} = value), do: value

  defp datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp datetime(_), do: nil

  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(_), do: nil

  defp format_cedis(amount_minor) when is_integer(amount_minor) do
    sign = if amount_minor < 0, do: "-", else: ""
    cents = abs(amount_minor)
    major = div(cents, 100)
    minor = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}₵#{commaize(major)}.#{minor}"
  end

  defp commaize(integer) when integer < 1000, do: Integer.to_string(integer)

  defp commaize(integer) do
    integer
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end
end
