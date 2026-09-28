defmodule Mithril.BookingCustomerReminder.Config do
  @moduledoc false

  @spec load() :: map()
  def load do
    hours_24 = int_env("BOOKING_CUSTOMER_REMINDER_HOURS", 24, min: 1)
    hours_48 = int_env("BOOKING_CUSTOMER_REMINDER_48H_HOURS", 48, min: hours_24 + 1)
    hours_7d = int_env("BOOKING_CUSTOMER_REMINDER_7D_HOURS", 24 * 7, min: hours_48 + 1)

    %{
      hours_24: hours_24,
      hours_48: hours_48,
      hours_7d: hours_7d,
      tolerance_hours: float_env("BOOKING_CUSTOMER_REMINDER_TOLERANCE_HOURS", 1.0, min: 0.5),
      morning_hour: int_env("BOOKING_CUSTOMER_REMINDER_MORNING_HOUR", 8, min: 0, max: 23),
      claim_ttl_minutes: int_env("BOOKING_REMINDER_CLAIM_TTL_MINUTES", 45, min: 5),
      batch_limit: 50
    }
  end

  defp int_env(name, default, opts) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, 1_000_000)

    parsed =
      case System.get_env(name) do
        nil ->
          default

        value ->
          case Integer.parse(String.trim(value)) do
            {integer, _} -> integer
            :error -> default
          end
      end

    parsed |> max(min) |> min(max)
  end

  defp float_env(name, default, opts) do
    min = Keyword.get(opts, :min, 0.0)

    parsed =
      case System.get_env(name) do
        nil ->
          default

        value ->
          case Float.parse(String.trim(value)) do
            {float, _} -> float
            :error -> default
          end
      end

    max(parsed, min)
  end
end
