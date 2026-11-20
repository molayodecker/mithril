defmodule Mithril.WhatsApp.BookingOfferTest do
  use ExUnit.Case, async: false

  alias Mithril.WhatsApp.BookingOffer

  @today ~D[2026-11-20]

  setup do
    previous = Application.get_env(:mithril, :booking_offer_complete)
    Application.delete_env(:mithril, :booking_offer_complete)

    on_exit(fn ->
      if previous do
        Application.put_env(:mithril, :booking_offer_complete, previous)
      else
        Application.delete_env(:mithril, :booking_offer_complete)
      end
    end)

    :ok
  end

  test "the next three mornings are the offered dates" do
    assert [
             %{index: 1, date: "2026-11-21", time: "09:00"},
             %{index: 2, date: "2026-11-22", time: "09:00"},
             %{index: 3, date: "2026-11-23", time: "09:00"}
           ] = BookingOffer.visit_slots(@today)
  end

  test "book starts an offer and a number picks that morning" do
    assert BookingOffer.choice("offered", "yes", "", @today) == :book
    assert BookingOffer.choice("offered", "", "book_visit", @today) == :book

    assert BookingOffer.choice("awaiting_time", "2", "", @today) ==
             {:schedule, "2026-11-22", "09:00"}

    assert BookingOffer.choice("awaiting_time", "2 at 2pm", "", @today) ==
             {:schedule, "2026-11-22", "14:00"}
  end

  test "a written date and time is accepted when it is still ahead" do
    assert BookingOffer.choice("awaiting_time", "tomorrow at 2pm", "", @today) ==
             {:schedule, "2026-11-21", "14:00"}

    assert BookingOffer.choice("awaiting_time", "Friday 9:30", "", @today) ==
             {:schedule, "2026-11-27", "09:30"}

    assert BookingOffer.choice("awaiting_time", "2026-11-19 at 10:00", "", @today) == :unknown
    assert BookingOffer.choice("offered", "2", "", @today) == :unknown
  end

  test "AM/PM clock values are not misread as morning times" do
    assert BookingOffer.choice("awaiting_time", "tomorrow at 2:30pm", "", @today) ==
             {:schedule, "2026-11-21", "14:30"}

    assert BookingOffer.choice("awaiting_time", "tomorrow at 12:30am", "", @today) ==
             {:schedule, "2026-11-21", "00:30"}

    assert BookingOffer.choice("awaiting_time", "tomorrow at 12:30pm", "", @today) ==
             {:schedule, "2026-11-21", "12:30"}
  end

  test "explicit day numbers are not treated as menu selections" do
    assert BookingOffer.choice("awaiting_time", "1 Dec at 2pm", "", @today) ==
             {:schedule, "2026-12-01", "14:00"}

    assert BookingOffer.choice("awaiting_time", "2 Dec at 2pm", "", @today) ==
             {:schedule, "2026-12-02", "14:00"}
  end

  test "open ai can read a spoken choice and cannot book a past day" do
    Application.put_env(:mithril, :booking_offer_complete, fn _prompt ->
      {:ok, %{"action" => "schedule", "date" => "2026-11-22", "time" => "15:00"}}
    end)

    assert BookingOffer.interpret("awaiting_time", "the second one in the afternoon", "", @today) ==
             {:schedule, "2026-11-22", "15:00"}

    Application.put_env(:mithril, :booking_offer_complete, fn _prompt ->
      {:ok, %{"action" => "schedule", "date" => "2026-11-19", "time" => "15:00"}}
    end)

    assert BookingOffer.interpret("awaiting_time", "yesterday", "", @today) == :unknown

    Application.put_env(:mithril, :booking_offer_complete, fn _prompt ->
      {:ok, %{"action" => "book"}}
    end)

    assert BookingOffer.interpret("offered", "please book it", "", @today) == :book
  end

  test "the stock reply keeps the agreed price" do
    reply =
      BookingOffer.stock_reply(%{
        event: "assigned",
        service: "Regular Cleaning",
        amount: "GHS 150.00",
        cleaner: "Ama",
        when: "2026-11-22 at 09:00",
        address: "12 Ring Road",
        slots: []
      })

    assert reply =~ "GHS 150.00"
    assert reply =~ "Ama"
    assert reply =~ "12 Ring Road"
  end
end
