defmodule Mithril.DirectContracts.Calendar do
  @moduledoc """
  Accra pay-period dates for client contracts.

  Ghana stays on GMT, so the UTC date is the Accra date.
  Weekday numbers match the admin form: 0 is Sunday through 6 is Saturday.
  Payday is the last Monday–Friday of the month.
  """

  @month_names ~w(January February March April May June July August September October November December)
  @short_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @short_weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)
  @weekday_names ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  @spec today() :: Date.t()
  def today, do: Date.utc_today()

  @spec parse_month(term()) :: {:ok, Date.t()} | :error
  def parse_month(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{4})-(\d{2})\z/, String.trim(value)) do
      [_, year, month] -> date_from_parts(String.to_integer(year), String.to_integer(month))
      _ -> :error
    end
  end

  def parse_month(_), do: :error

  @spec parse_date(term()) :: {:ok, Date.t()} | :error
  def parse_date(%Date{} = date), do: {:ok, date}

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def parse_date(_), do: :error

  @spec period_start(Date.t()) :: Date.t()
  def period_start(%Date{} = date), do: %{date | day: 1}

  @spec period_end(Date.t()) :: Date.t()
  def period_end(%Date{} = month_start), do: Date.end_of_month(month_start)

  @spec last_working_day(Date.t()) :: Date.t()
  def last_working_day(%Date{} = month_start) do
    last = Date.end_of_month(month_start)

    shift =
      case Date.day_of_week(last) do
        6 -> -1
        7 -> -2
        _ -> 0
      end

    Date.add(last, shift)
  end

  @spec weekday_dates(Date.t(), integer()) :: [Date.t()]
  def weekday_dates(%Date{} = month_start, weekday) when weekday in 0..6 do
    target = if weekday == 0, do: 7, else: weekday
    last = Date.end_of_month(month_start)
    offset = rem(target - Date.day_of_week(month_start) + 7, 7)
    first = Date.add(month_start, offset)

    Stream.iterate(first, &Date.add(&1, 7))
    |> Enum.take_while(&(Date.compare(&1, last) != :gt))
  end

  @spec week_status(Date.t(), Date.t(), boolean()) :: String.t()
  def week_status(%Date{}, %Date{}, true), do: "paid"

  def week_status(%Date{} = week, %Date{} = today, false) do
    if Date.compare(week, today) == :gt, do: "upcoming", else: "due"
  end

  @spec month_label(Date.t()) :: String.t()
  def month_label(%Date{} = month_start) do
    "#{Enum.at(@month_names, month_start.month - 1)} #{month_start.year}"
  end

  @spec month_key(Date.t()) :: String.t()
  def month_key(%Date{} = month_start) do
    :io_lib.format("~4..0B-~2..0B", [month_start.year, month_start.month])
    |> IO.iodata_to_binary()
  end

  @spec short_date(Date.t()) :: String.t()
  def short_date(%Date{} = date) do
    weekday = Enum.at(@short_weekdays, Date.day_of_week(date) - 1)
    month = Enum.at(@short_months, date.month - 1)
    "#{weekday} #{date.day} #{month}"
  end

  @spec weekday_name(integer()) :: String.t()
  def weekday_name(weekday) when weekday in 0..6, do: Enum.at(@weekday_names, weekday)

  @spec shift_month(Date.t(), integer()) :: Date.t()
  def shift_month(%Date{} = month_start, delta) when is_integer(delta) do
    Date.shift(month_start, month: delta)
  end

  @spec invoice_months(DateTime.t() | NaiveDateTime.t() | Date.t(), Date.t()) :: [Date.t()]
  def invoice_months(created_at, %Date{} = today) do
    first = period_start(to_date(created_at))
    last = shift_month(period_start(today), 1)
    last = if Date.compare(last, first) == :lt, do: first, else: last

    Stream.iterate(first, &shift_month(&1, 1))
    |> Enum.take_while(&(Date.compare(&1, last) != :gt))
    |> Enum.take(18)
  end

  @spec net_minor(integer(), integer()) :: integer()
  def net_minor(gross, advances) when is_integer(gross) and is_integer(advances) do
    max(0, gross - max(0, advances))
  end

  @spec format_ghs(integer()) :: String.t()
  def format_ghs(minor) when is_integer(minor) do
    sign = if minor < 0, do: "-", else: ""
    absolute = abs(minor)
    whole = div(absolute, 100)
    fraction = absolute |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "GHS #{sign}#{whole}.#{fraction}"
  end

  defp date_from_parts(year, month) when month in 1..12 do
    case Date.new(year, month, 1) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp date_from_parts(_, _), do: :error

  defp to_date(%Date{} = date), do: date
  defp to_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp to_date(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
end
