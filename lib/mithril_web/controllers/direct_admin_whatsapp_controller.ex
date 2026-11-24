defmodule MithrilWeb.DirectAdminWhatsAppController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminWhatsApp
  alias Mithril.WhatsApp.BookingOffer

  alias MithrilWeb.Schemas.DirectAdminWhatsApp.{
    BookingOfferRequest,
    BookingOfferResponse,
    BookingOfferScheduleRequest
  }

  alias MithrilWeb.Schemas.DirectAdminWhatsApp.{
    CustomerRequest,
    CustomerResponse,
    MessageListResponse,
    MutationResponse,
    SendRequest,
    ThreadListResponse
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-whatsapp"])

  operation(:index,
    operation_id: "direct.listAdminWhatsAppThreads",
    summary: "List WhatsApp inbox threads",
    responses: [ok: {"Threads", "application/json", ThreadListResponse}]
  )

  def index(conn, _params) do
    respond(conn, DirectAdminWhatsApp.list_threads(user_id(conn)), fn threads ->
      %{threads: threads}
    end)
  end

  operation(:messages,
    operation_id: "direct.listAdminWhatsAppMessages",
    summary: "List WhatsApp messages for a phone number",
    parameters: [
      phone: [
        in: :query,
        schema: %Schema{type: :string},
        required: true,
        description: "Customer phone in E.164"
      ]
    ],
    responses: [ok: {"Messages", "application/json", MessageListResponse}]
  )

  def messages(conn, params) do
    respond(
      conn,
      DirectAdminWhatsApp.list_messages(user_id(conn), params["phone"]),
      fn messages ->
        %{messages: messages}
      end
    )
  end

  operation(:send,
    operation_id: "direct.sendAdminWhatsAppMessage",
    summary: "Send a WhatsApp session message from ops",
    request_body: {"Send WhatsApp", "application/json", SendRequest},
    responses: [ok: {"Sent", "application/json", MutationResponse}]
  )

  def send(conn, params) do
    respond(conn, DirectAdminWhatsApp.send_message(user_id(conn), params))
  end

  operation(:sms,
    operation_id: "direct.sendAdminWhatsAppSms",
    summary: "Send an SMS to the open WhatsApp thread phone",
    request_body: {"Send SMS", "application/json", SendRequest},
    responses: [ok: {"Sent", "application/json", MutationResponse}]
  )

  def sms(conn, params) do
    respond(conn, DirectAdminWhatsApp.send_sms(user_id(conn), params))
  end

  operation(:create_customer,
    operation_id: "direct.createAdminWhatsAppCustomer",
    summary: "Create a customer account for a WhatsApp number",
    request_body: {"Customer", "application/json", CustomerRequest},
    responses: [ok: {"Customer", "application/json", CustomerResponse}]
  )

  def create_customer(conn, params) do
    respond(conn, DirectAdminWhatsApp.create_customer(user_id(conn), params))
  end

  operation(:booking_offer,
    operation_id: "direct.startAdminWhatsAppBookingOffer",
    summary: "Send a priced WhatsApp booking offer",
    request_body: {"Booking offer", "application/json", BookingOfferRequest},
    responses: [ok: {"Offer", "application/json", BookingOfferResponse}]
  )

  def booking_offer(conn, params) do
    respond(conn, BookingOffer.start(user_id(conn), params))
  end

  operation(:booking_offer_show,
    operation_id: "direct.getAdminWhatsAppBookingOffer",
    summary: "Read the latest WhatsApp booking offer for a phone",
    parameters: [
      phone: [in: :query, schema: %Schema{type: :string}, required: true]
    ],
    responses: [ok: {"Offer", "application/json", BookingOfferResponse}]
  )

  def booking_offer_show(conn, params) do
    respond(conn, BookingOffer.fetch(user_id(conn), params["phone"]))
  end

  operation(:booking_offer_accept,
    operation_id: "direct.acceptAdminWhatsAppBookingOffer",
    summary: "Mark a WhatsApp booking offer accepted and return time options",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [ok: {"Offer", "application/json", BookingOfferResponse}]
  )

  def booking_offer_accept(conn, %{"id" => id}) do
    respond(conn, BookingOffer.accept(user_id(conn), id))
  end

  operation(:booking_offer_schedule,
    operation_id: "direct.scheduleAdminWhatsAppBookingOffer",
    summary: "Create the booking at the chosen time and assign the nearest cleaner",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Schedule", "application/json", BookingOfferScheduleRequest},
    responses: [ok: {"Offer", "application/json", BookingOfferResponse}]
  )

  def booking_offer_schedule(conn, %{"id" => id} = params) do
    respond(conn, BookingOffer.schedule(user_id(conn), id, params))
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
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invalid_phone), do: {422, "invalid_phone"}
  defp error_response(:twilio_not_configured), do: {503, "twilio_not_configured"}
  defp error_response(:sms_not_configured), do: {503, "sms_not_configured"}
  defp error_response(:sms_delivery_failed), do: {502, "sms_delivery_failed"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
