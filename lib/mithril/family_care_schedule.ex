defmodule Mithril.FamilyCareSchedule do
  @moduledoc """
  Visit dates for one paid Family Care period.

  Weekly and custom plans use the seven-day window that starts on the anchor.
  Monthly plans include Monday–Friday from the anchor through the end of that
  month, plus any Saturday or Sunday the customer added.
  """

  @weekday_names ~w(mon tue wed thu fri sat sun)
  @weekend_names ~w(sat sun)

  @spec visit_dates(map() | nil, Date.t()) :: [Date.t()]
  def visit_dates(nil, %Date{} = anchor), do: [anchor]

  def visit_dates(%{"frequency" => "monthly"} = schedule, %Date{} = anchor) do
    weekends = MapSet.new(weekend_names(schedule["weekdays"]))
    month_end = Date.end_of_month(anchor)

    Date.range(anchor, month_end)
    |> Enum.filter(fn date ->
      name = weekday_name(date)
      name not in @weekend_names or name in weekends
    end)
  end

  def visit_dates(%{"frequency" => frequency} = schedule, %Date{} = anchor)
      when frequency in ["weekly", "custom"] do
    selected = MapSet.new(stored_weekdays(frequency, schedule["weekdays"], anchor))

    0..6
    |> Enum.map(&Date.add(anchor, &1))
    |> Enum.filter(fn date -> weekday_name(date) in selected end)
  end

  def visit_dates(_schedule, %Date{} = anchor), do: [anchor]

  @spec stored_weekdays(String.t(), [String.t()] | nil, Date.t(), integer() | nil) :: [String.t()]
  def stored_weekdays(frequency, weekdays, anchor, selected_count \\ nil)

  def stored_weekdays("monthly", weekdays, _anchor, _selected_count) do
    weekend_names(weekdays)
  end

  def stored_weekdays(frequency, weekdays, %Date{} = anchor, selected_count)
      when frequency in ["weekly", "custom"] do
    names = weekday_names(weekdays)

    cond do
      names != [] -> names
      frequency == "weekly" and selected_count == 1 -> [weekday_name(anchor)]
      frequency == "weekly" -> @weekday_names
      true -> [weekday_name(anchor)]
    end
  end

  def stored_weekdays(_frequency, _weekdays, %Date{} = anchor, _selected_count),
    do: [weekday_name(anchor)]

  @spec period_start(String.t() | nil, Date.t()) :: Date.t()
  def period_start("monthly", %Date{} = anchor), do: Date.beginning_of_month(anchor)
  def period_start(_frequency, %Date{} = anchor), do: anchor

  @spec weekday_name(Date.t()) :: String.t()
  def weekday_name(%Date{} = date) do
    Enum.at(@weekday_names, Date.day_of_week(date) - 1)
  end

  defp weekday_names(weekdays) when is_list(weekdays) do
    weekdays
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in @weekday_names))
    |> Enum.uniq()
  end

  defp weekday_names(_weekdays), do: []

  defp weekend_names(weekdays) do
    weekdays
    |> weekday_names()
    |> Enum.filter(&(&1 in @weekend_names))
  end
end
