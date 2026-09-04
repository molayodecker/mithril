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
      duration_hours: dump_decimal(booking.duration_hours),
      address: booking.address,
      special_instructions: booking.special_instructions,
      status: booking.status,
      total_price: dump_decimal(booking.total_price),
      platform_fee: dump_decimal(booking.platform_fee),
      tax_amount: dump_decimal(booking.tax_amount),
      payment_status: booking.payment_status,
      payment_method: booking.payment_method,
      created_at: booking.created_at,
      updated_at: booking.updated_at
    }
  end

  defp dump_decimal(nil), do: nil

  defp dump_decimal(%Decimal{} = value) do
    normalized = Decimal.normalize(value)

    if Decimal.integer?(normalized) do
      Decimal.to_integer(normalized)
    else
      Decimal.to_string(normalized, :normal)
    end
  end
end
