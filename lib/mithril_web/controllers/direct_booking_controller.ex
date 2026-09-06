defmodule MithrilWeb.DirectBookingController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectBookings

  alias MithrilWeb.Schemas.DirectBooking.{
    BookingDetailResponse,
    BookingPriceResponse,
    BookingPricingRequest,
    BookingServicesResponse,
    CreateBookingRequest,
    CreateBookingResponse,
    CleanerListResponse
  }

  alias OpenApiSpex.Schema

  tags(["direct-bookings"])

  operation(:list_services,
    operation_id: "direct.listBookingServices",
    summary: "List active services available for Direct booking",
    responses: [ok: {"Booking services", "application/json", BookingServicesResponse}]
  )

  def list_services(conn, _params) do
    respond(conn, DirectBookings.list_services(), fn services -> %{services: services} end)
  end

  operation(:list_cleaners,
    operation_id: "direct.listBookingCleaners",
    summary: "List active verified professionals available for direct selection",
    responses: [ok: {"Booking professionals", "application/json", CleanerListResponse}]
  )

  def list_cleaners(conn, _params) do
    respond(conn, DirectBookings.list_cleaners(), fn cleaners -> %{cleaners: cleaners} end)
  end

  operation(:preview_price,
    operation_id: "direct.previewBookingPrice",
    summary: "Compute authoritative booking pricing",
    request_body: {"Booking pricing input", "application/json", BookingPricingRequest, required: true},
    responses: [ok: {"Authoritative booking price", "application/json", BookingPriceResponse}]
  )

  def preview_price(conn, params) do
    respond(conn, DirectBookings.preview_price(params))
  end

  operation(:create,
    operation_id: "direct.createBooking",
    summary: "Create a pending Instaclean booking",
    request_body: {"Booking", "application/json", CreateBookingRequest, required: true},
    responses: [ok: {"Created booking", "application/json", CreateBookingResponse}]
  )

  def create(conn, params) do
    respond(conn, DirectBookings.create_booking(user_id(conn), params))
  end

  operation(:show,
    operation_id: "direct.showBooking",
    summary: "Get a signed-in customer's booking",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    responses: [ok: {"Booking", "application/json", BookingDetailResponse}]
  )

  def show(conn, %{"id" => id}) do
    respond(conn, DirectBookings.get_booking(user_id(conn), id))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, result, mapper \\ & &1)

  defp respond(conn, {:ok, value}, mapper) do
    json(conn, mapper.(value))
  end

  defp respond(conn, {:error, reason}, _mapper) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:invalid_service), do: {422, "invalid_service"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:pricing_unavailable), do: {422, "pricing_unavailable"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
