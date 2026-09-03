defmodule MithrilWeb.ParityBookingController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Bookings

  def show(conn, %{"id" => id}) do
    case Bookings.get_booking(id) do
      {:ok, booking} ->
        json(conn, %{booking: serialize(booking)})

      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_booking_id"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "booking_not_found"})
    end
  end

  defp serialize(booking) do
    %{
      id: booking.id,
      customer_id: booking.customer_id,
      cleaner_id: booking.cleaner_id,
      service_id: booking.service_id,
      scheduled_date: booking.scheduled_date,
      scheduled_time: booking.scheduled_time,
      duration_hours: booking.duration_hours,
      address: booking.address,
      special_instructions: booking.special_instructions,
      status: booking.status,
      total_price: booking.total_price,
      platform_fee: booking.platform_fee,
      tax_amount: booking.tax_amount,
      payment_status: booking.payment_status,
      payment_method: booking.payment_method,
      created_at: booking.created_at,
      updated_at: booking.updated_at
    }
  end
end
