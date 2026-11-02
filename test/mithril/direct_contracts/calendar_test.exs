defmodule Mithril.DirectContracts.CalendarTest do
  use ExUnit.Case, async: true

  alias Mithril.DirectContracts.Calendar

  test "October 2026 payday is the last working day, and Fridays are not assumed to be four" do
    october = ~D[2026-10-01]
    assert Calendar.last_working_day(october) == ~D[2026-10-30]

    assert Calendar.weekday_dates(october, 5) == [
             ~D[2026-10-02],
             ~D[2026-10-09],
             ~D[2026-10-16],
             ~D[2026-10-23],
             ~D[2026-10-30]
           ]

    assert Calendar.net_minor(120_000, 80_000) == 40_000
    assert Calendar.net_minor(120_000, 130_000) == 0
    assert Calendar.format_ghs(400_000) == "GHS 4000.00"
    assert Calendar.month_label(october) == "October 2026"
    assert Calendar.short_date(~D[2026-10-30]) == "Fri 30 Oct"
  end

  test "a week is due on its date and paid once a credit exists" do
    assert Calendar.week_status(~D[2026-10-30], ~D[2026-10-30], false) == "due"
    assert Calendar.week_status(~D[2026-10-30], ~D[2026-10-30], true) == "paid"
    assert Calendar.week_status(~D[2026-11-06], ~D[2026-10-30], false) == "upcoming"
  end
end
