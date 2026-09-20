defmodule MithrilWeb.DirectAdminBookingsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectAdminBookings

  alias MithrilWeb.Schemas.DirectAdminBooking.{
    AdminBooking,
    AdminBookingListResponse,
    AssignCleanerRequest,
    CashPayoutRequest,
    CashPayoutResponse,
    MutationOkResponse,
    NotifyResponse,
    ResetHoldRequest,
    UpdateStatusRequest
  }

  alias MithrilWeb.Schemas.DirectBooking.{
    CancelBookingRequest,
    CancelBookingResponse,
    RescheduleBookingRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-bookings"])

  operation(:index,
    operation_id: "direct.listAdminBookings",
    summary: "List bookings for Direct operations",
    parameters: [
      q: [
        in: :query,
        schema: %Schema{type: :string, maxLength: 120},
        required: false,
        description: "Search address, customer, cleaner, or booking id"
      ],
      status: [
        in: :query,
        schema: %Schema{type: :string},
        required: false,
        description: "Booking status filter"
      ],
      paymentStatus: [
        in: :query,
        schema: %Schema{type: :string},
        required: false,
        description: "Payment status filter"
      ]
    ],
    responses: [ok: {"Admin bookings", "application/json", AdminBookingListResponse}]
  )

  def index(conn, params) do
    respond(conn, DirectAdminBookings.list_bookings(user_id(conn), params), fn bookings ->
      %{bookings: bookings}
    end)
  end

  operation(:show,
    operation_id: "direct.showAdminBooking",
    summary: "Get a booking for Direct operations",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    responses: [ok: {"Admin booking", "application/json", AdminBooking}]
  )

  def show(conn, %{"id" => id}) do
    respond(conn, DirectAdminBookings.get_booking(user_id(conn), id))
  end

  operation(:assign,
    operation_id: "direct.assignAdminBookingCleaner",
    summary: "Assign or change the cleaner on a booking that has not started",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body:
      {"Cleaner assignment", "application/json", AssignCleanerRequest, required: true},
    responses: [ok: {"Updated booking", "application/json", AdminBooking}]
  )

  def assign(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBookings.assign_cleaner(user_id(conn), id, params))
  end

  operation(:update_status,
    operation_id: "direct.updateAdminBookingStatus",
    summary: "Set an admin-assignable booking status",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"Booking status", "application/json", UpdateStatusRequest, required: true},
    responses: [ok: {"Updated booking", "application/json", AdminBooking}]
  )

  def update_status(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBookings.update_status(user_id(conn), id, params))
  end

  operation(:cancel,
    operation_id: "direct.cancelAdminBooking",
    summary: "Cancel a booking and refund per Instaclean policy",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"Cancellation", "application/json", CancelBookingRequest},
    responses: [ok: {"Cancelled booking", "application/json", CancelBookingResponse}]
  )

  def cancel(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBookings.cancel(user_id(conn), id, params))
  end

  operation(:reschedule,
    operation_id: "direct.rescheduleAdminBooking",
    summary: "Reschedule a booking from Direct operations",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"New schedule", "application/json", RescheduleBookingRequest, required: true},
    responses: [ok: {"Updated booking", "application/json", AdminBooking}]
  )

  def reschedule(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBookings.reschedule(user_id(conn), id, params))
  end

  operation(:reset_hold,
    operation_id: "direct.resetAdminBookingExclusiveHold",
    summary: "Reset a stuck exclusive cleaner-accept hold",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"Hold reset", "application/json", ResetHoldRequest},
    responses: [ok: {"Hold reset", "application/json", MutationOkResponse}]
  )

  def reset_hold(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBookings.reset_exclusive_hold(user_id(conn), id, params))
  end

  operation(:cash_payout,
    operation_id: "direct.recordAdminBookingCashPayout",
    summary: "Record a cash payout against a completed paid booking",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"Cash payout", "application/json", CashPayoutRequest, required: true},
    responses: [ok: {"Recorded payout", "application/json", CashPayoutResponse}]
  )

  def cash_payout(conn, %{"id" => id} = params) do
    respond(conn, DirectAdminBookings.record_cash_payout(user_id(conn), id, params))
  end

  operation(:notify_cleaner,
    operation_id: "direct.notifyAdminBookingCleaner",
    summary: "Send the assigned cleaner a booking reminder",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    responses: [ok: {"Notify result", "application/json", NotifyResponse}]
  )

  def notify_cleaner(conn, %{"id" => id}) do
    respond(conn, DirectAdminBookings.notify_cleaner(user_id(conn), id))
  end

  operation(:send_receipt,
    operation_id: "direct.sendAdminBookingReceipt",
    summary: "Send the customer a booking receipt reminder",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    responses: [ok: {"Receipt result", "application/json", NotifyResponse}]
  )

  def send_receipt(conn, %{"id" => id}) do
    respond(conn, DirectAdminBookings.send_receipt(user_id(conn), id))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, result, mapper \\ & &1)

  defp respond(conn, {:ok, value}, mapper) do
    json(conn, mapper.(value))
  end

  defp respond(conn, {:error, {reason, message}}, _mapper) when is_binary(message) do
    {status, code} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: code, message: message})
  end

  defp respond(conn, {:error, reason}, _mapper) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:not_cancellable), do: {409, "not_cancellable"}
  defp error_response(:cancel_conflict), do: {409, "cancel_conflict"}
  defp error_response(:not_reschedulable), do: {409, "not_reschedulable"}
  defp error_response(:not_reassignable), do: {409, "not_reassignable"}
  defp error_response(:already_accepted), do: {409, "already_accepted"}
  defp error_response(:hold_still_active), do: {409, "hold_still_active"}
  defp error_response(:past_schedule), do: {422, "past_schedule"}
  defp error_response(:cleaner_unavailable), do: {422, "cleaner_unavailable"}
  defp error_response(:cleaner_missing), do: {422, "cleaner_missing"}
  defp error_response(:missing_contact), do: {422, "missing_contact"}
  defp error_response(:invalid_status), do: {422, "invalid_status"}
  defp error_response(:invalid_status_transition), do: {409, "invalid_status_transition"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invalid_timeslot), do: {422, "invalid_timeslot"}
  defp error_response(:insufficient_balance), do: {409, "insufficient_balance"}
  defp error_response(:wallet_not_found), do: {409, "wallet_not_found"}
  defp error_response(:invalid_amount), do: {422, "invalid_amount"}
  defp error_response(:cash_payout_already_recorded), do: {409, "cash_payout_already_recorded"}

  defp error_response(:booking_has_no_cleaner_earnings),
    do: {409, "booking_has_no_cleaner_earnings"}

  defp error_response(:amount_exceeds_booking_earnings),
    do: {409, "amount_exceeds_booking_earnings"}

  defp error_response(:booking_not_completed), do: {409, "booking_not_completed"}
  defp error_response(:booking_not_paid), do: {409, "booking_not_paid"}
  defp error_response(:booking_cleaner_mismatch), do: {409, "booking_cleaner_mismatch"}
  defp error_response(:unknown), do: {422, "unknown"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
