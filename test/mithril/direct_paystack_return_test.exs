defmodule Mithril.DirectPaystackReturnTest do
  use ExUnit.Case, async: true

  alias Mithril.DirectPaystackReturn

  @booking_id "550e8400-e29b-4164-a716-446655440000"

  test "valid_booking_id? accepts UUIDs" do
    assert DirectPaystackReturn.valid_booking_id?(@booking_id)
    refute DirectPaystackReturn.valid_booking_id?("not-a-uuid")
  end

  test "build_deep_link includes bookingId, source, and optional reference" do
    assert DirectPaystackReturn.build_deep_link(@booking_id,
             scheme: "instaclean-preview",
             reference: "BK-123"
           ) ==
             "instaclean-preview://booking-status?bookingId=#{URI.encode(@booking_id)}&source=payment&reference=BK-123"
  end

  test "normalize_scheme falls back for structured public input" do
    assert DirectPaystackReturn.normalize_scheme(%{"value" => "instaclean-preview"}) == "instaclean"
    assert DirectPaystackReturn.normalize_scheme(["instaclean-preview"]) == "instaclean"
  end

  test "resolve_from_query reads scheme and Paystack reference params" do
    deep_link =
      DirectPaystackReturn.resolve_from_query(@booking_id, %{
        "scheme" => "instaclean-preview",
        "trxref" => "BK-ref"
      })

    assert deep_link =~ "instaclean-preview://booking-status?"
    assert deep_link =~ "bookingId=#{URI.encode(@booking_id)}"
    assert deep_link =~ "reference=BK-ref"
  end

  test "redirect_html escapes and embeds the deep link" do
    target = "instaclean://booking-status?bookingId=abc&source=payment"
    html = DirectPaystackReturn.redirect_html(target)

    assert html =~ "Returning to Instaclean"
    assert html =~ "window.location.replace"
    assert html =~ Jason.encode!(target)
  end
end
