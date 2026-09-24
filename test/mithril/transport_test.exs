defmodule Mithril.Transport.PricingTest do
  use ExUnit.Case, async: true

  alias Mithril.Transport.Pricing
  alias Mithril.Transport.UberHandoff

  test "quotes a transport allowance from distance using default rules" do
    assert {:ok, quote} = Pricing.quote(4.2)
    assert quote.currency == "GHS"
    assert quote.distance_km == 4.2
    assert quote.amount_minor >= 1500
    assert quote.amount_minor <= 15_000
  end

  test "rejects negative distances" do
    assert {:error, :invalid_distance} = Pricing.quote(-1)
  end

  test "builds an Uber handoff URL without exposing it as an estimate API" do
    origin = %{latitude: 5.6, longitude: -0.2}
    dest = %{latitude: 5.65, longitude: -0.18}

    url = UberHandoff.url(origin, dest, "East Legon")
    assert url =~ "https://m.uber.com/looking?"
    assert url =~ "pickup="
    refute url =~ "estimates/price"
  end

  test "only assigned cleaners on confirmed bookings receive a handoff URL" do
    customer_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    origin = %{latitude: 5.6, longitude: -0.2}
    dest = %{latitude: 5.65, longitude: -0.18}

    booking = %{
      "customer_id" => customer_id,
      "cleaner_id" => cleaner_id,
      "status" => "confirmed",
      "address" => "East Legon"
    }

    assert is_binary(UberHandoff.maybe_url(cleaner_id, booking, origin, dest))
    assert UberHandoff.maybe_url(customer_id, booking, origin, dest) == nil

    assert UberHandoff.maybe_url(cleaner_id, Map.put(booking, "status", "pending"), origin, dest) ==
             nil
  end
end

defmodule Mithril.Transport.LocationIQParseTest do
  use ExUnit.Case, async: true

  alias Mithril.Transport.Router.LocationIQ

  test "parses a directions payload into meters and seconds" do
    assert {:ok, %{distance_m: 4200.0, duration_s: 780.0}} =
             LocationIQ.parse_directions_fixture(%{
               "code" => "Ok",
               "routes" => [%{"distance" => 4200, "duration" => 780}]
             })
  end
end
