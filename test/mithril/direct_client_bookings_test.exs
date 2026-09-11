defmodule Mithril.DirectClientBookingsTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectBookings

  test "client self-serve booking is disabled unless the flag is on" do
    customer_id = Ecto.UUID.generate()

    assert {:error, :client_bookings_disabled} =
             DirectBookings.create_customer_booking(customer_id, %{})

    previous = Application.get_env(:mithril, :direct_client_bookings, false)
    Application.put_env(:mithril, :direct_client_bookings, true)

    on_exit(fn ->
      Application.put_env(:mithril, :direct_client_bookings, previous)
    end)

    assert {:error, :invalid_user} = DirectBookings.create_customer_booking("not-a-uuid", %{})
  end
end
