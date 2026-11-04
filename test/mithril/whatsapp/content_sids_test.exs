defmodule Mithril.WhatsApp.ContentSidsTest do
  use ExUnit.Case, async: true

  alias Mithril.WhatsApp.ContentSids

  test "worker and authentication templates replace the previous content SIDs" do
    assert ContentSids.template("cleaner_assigned") == "HX1658bbc9404a734f86eee1a972a6b5c8"
    assert ContentSids.template("phone_otp") == "HX0c13fa64693fc800d33ee2fe82d64c75"
    assert ContentSids.template("booking_rescheduled") == "HX334c4009d26198d355be63420554a26d"
    assert ContentSids.template("booking_reminder") == nil
  end

  test "application quick replies use the Worker templates" do
    assert ContentSids.quick_reply(:yes_no) == "HX94459b817d4508364b9ea383be3974d3"
    assert ContentSids.quick_reply(:accept) == "HX7c4c736e02d753ce38233fe15e73dbe4"
    assert ContentSids.quick_reply(:welcome) == nil
  end
end
