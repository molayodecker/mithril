defmodule Mithril.StripeChargeCurrencyTest do
  use ExUnit.Case, async: true

  alias Mithril.StripeChargeCurrency

  test "converts GHS booking minor units to USD presentment" do
    assert {:ok, charge} =
             StripeChargeCurrency.presentment_charge(%{
               booking_amount_minor: 10_000,
               booking_currency: "GHS",
               usd_per_ghs: 0.08
             })

    assert charge.currency == "usd"
    assert charge.amount_minor >= 50
    assert charge.source_amount_minor == 10_000
  end

  test "rejects amounts below the Stripe USD minimum" do
    assert {:error, message} =
             StripeChargeCurrency.presentment_charge(%{
               booking_amount_minor: 100,
               booking_currency: "GHS",
               usd_per_ghs: 0.08
             })

    assert message =~ "too small"
  end
end
