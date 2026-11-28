defmodule Mithril.FamilyCareScheduleTest do
  use ExUnit.Case, async: true

  alias Mithril.FamilyCareSchedule

  test "a full child-care month keeps the package visit count for 20 and 23 weekdays" do
    february =
      FamilyCareSchedule.visit_dates(
        %{"frequency" => "monthly", "weekdays" => []},
        ~D[2027-02-01]
      )

    march =
      FamilyCareSchedule.visit_dates(
        %{"frequency" => "monthly", "weekdays" => []},
        ~D[2027-03-01]
      )

    assert length(february) == 20
    assert length(march) == 23
    assert hd(february) == ~D[2027-02-01]
    assert Enum.all?(february, &(Date.day_of_week(&1) <= 5))
    assert Enum.all?(march, &(Date.day_of_week(&1) <= 5))
  end

  test "optional weekend days are added inside the same monthly period" do
    dates =
      FamilyCareSchedule.visit_dates(
        %{"frequency" => "monthly", "weekdays" => ["sat"]},
        ~D[2027-03-01]
      )

    saturdays = Enum.filter(dates, &(Date.day_of_week(&1) == 6))
    assert length(saturdays) == 4
    assert length(dates) == 27
  end

  test "weekly and custom windows follow the selected weekdays" do
    week =
      FamilyCareSchedule.visit_dates(
        %{"frequency" => "weekly", "weekdays" => ~w(mon tue wed thu fri sat sun)},
        ~D[2027-03-01]
      )

    custom =
      FamilyCareSchedule.visit_dates(
        %{"frequency" => "custom", "weekdays" => ~w(mon wed fri)},
        ~D[2027-03-01]
      )

    monday =
      FamilyCareSchedule.visit_dates(
        %{"frequency" => "weekly", "weekdays" => ["mon"]},
        ~D[2027-03-01]
      )

    assert length(week) == 7
    assert length(custom) == 3
    assert monday == [~D[2027-03-01]]
  end
end
