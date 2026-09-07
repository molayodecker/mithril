defmodule MithrilWeb.DirectOperationsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectOperations

  alias MithrilWeb.Schemas.DirectOperations.{
    CancelBookingRequest,
    CancellationPolicyResponse,
    CleanerApplicationListResponse,
    CleanerApprovalResponse,
    CleanerListResponse,
    PaymentDiagnosticsResponse,
    RefundRequest,
    RefundRequestResponse,
    RescheduleBookingRequest,
    RescheduleBookingResponse
  }

  alias OpenApiSpex.Schema

  tags(["direct-operations"])

  operation(:cancellation_policy,
    operation_id: "direct.getCancellationPolicy",
    summary: "Preview cancellation eligibility and policy-derived refund amount",
    parameters: [id: booking_id_parameter()],
    responses: [ok: {"Cancellation policy", "application/json", CancellationPolicyResponse}]
  )

  def cancellation_policy(conn, %{"id" => id}) do
    respond(conn, DirectOperations.cancellation_policy(user_id(conn), id))
  end

  operation(:cancel_booking,
    operation_id: "direct.cancelBooking",
    summary: "Cancel an owned booking or an admin-accessible booking",
    parameters: [id: booking_id_parameter()],
    request_body: {"Cancellation", "application/json", CancelBookingRequest},
    responses: [ok: {"Cancellation result", "application/json", %Schema{type: :object}}]
  )

  def cancel_booking(conn, %{"id" => id} = params) do
    respond(conn, DirectOperations.cancel_booking(user_id(conn), id, params))
  end

  operation(:request_refund,
    operation_id: "direct.requestRefund",
    summary: "Create an auditable refund request without directly issuing money",
    parameters: [id: booking_id_parameter()],
    request_body: {"Refund request", "application/json", RefundRequest, required: true},
    responses: [ok: {"Refund request", "application/json", RefundRequestResponse}]
  )

  def request_refund(conn, %{"id" => id} = params) do
    respond(conn, DirectOperations.request_refund(user_id(conn), id, params))
  end

  operation(:reschedule_booking,
    operation_id: "direct.rescheduleBooking",
    summary: "Reschedule a paid one-off booking after availability revalidation",
    parameters: [id: booking_id_parameter()],
    request_body: {"New schedule", "application/json", RescheduleBookingRequest, required: true},
    responses: [ok: {"Updated booking schedule", "application/json", RescheduleBookingResponse}]
  )

  def reschedule_booking(conn, %{"id" => id} = params) do
    respond(conn, DirectOperations.reschedule_booking(user_id(conn), id, params))
  end

  operation(:list_admin_cleaners,
    operation_id: "direct.listAdminCleaners",
    summary: "List Instaclean cleaners for operations",
    parameters: [
      q: [in: :query, schema: %Schema{type: :string, maxLength: 120}, required: false],
      status: [in: :query, schema: %Schema{type: :string}, required: false],
      verified: [in: :query, schema: %Schema{type: :boolean}, required: false],
      limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 200}, required: false]
    ],
    responses: [ok: {"Cleaner roster", "application/json", CleanerListResponse}]
  )

  def list_admin_cleaners(conn, params) do
    respond(conn, DirectOperations.list_cleaners(user_id(conn), params), fn cleaners ->
      %{cleaners: cleaners}
    end)
  end

  operation(:list_admin_cleaner_applications,
    operation_id: "direct.listAdminCleanerApplications",
    summary: "List cleaner applications for review and approval",
    parameters: [
      q: [in: :query, schema: %Schema{type: :string, maxLength: 120}, required: false],
      status: [in: :query, schema: %Schema{type: :string}, required: false],
      limit: [in: :query, schema: %Schema{type: :integer, minimum: 1, maximum: 200}, required: false]
    ],
    responses: [ok: {"Cleaner applications", "application/json", CleanerApplicationListResponse}]
  )

  def list_admin_cleaner_applications(conn, params) do
    respond(conn, DirectOperations.list_cleaner_applications(user_id(conn), params), fn applications ->
      %{applications: applications}
    end)
  end

  operation(:approve_cleaner_application,
    operation_id: "direct.approveCleanerApplication",
    summary: "Approve a cleaner application using the canonical database approval function",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Cleaner application ID"
      ]
    ],
    responses: [ok: {"Approved cleaner", "application/json", CleanerApprovalResponse}]
  )

  def approve_cleaner_application(conn, %{"id" => id}) do
    respond(conn, DirectOperations.approve_cleaner_application(user_id(conn), id))
  end

  operation(:payment_diagnostics,
    operation_id: "direct.getPaymentDiagnostics",
    summary: "Explain payment state using local attempts and Paystack verification",
    parameters: [id: booking_id_parameter()],
    responses: [ok: {"Payment diagnostics", "application/json", PaymentDiagnosticsResponse}]
  )

  def payment_diagnostics(conn, %{"id" => id}) do
    respond(conn, DirectOperations.payment_diagnostics(user_id(conn), id))
  end

  defp booking_id_parameter do
    [
      in: :path,
      schema: %Schema{type: :string, format: :uuid},
      required: true,
      description: "Booking ID"
    ]
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
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:application_not_found), do: {404, "application_not_found"}
  defp error_response(:application_user_not_found), do: {409, "application_user_not_found"}
  defp error_response(:already_refunded), do: {409, "already_refunded"}
  defp error_response(:payment_not_refundable), do: {409, "payment_not_refundable"}
  defp error_response(:booking_not_cancellable), do: {409, "booking_not_cancellable"}
  defp error_response(:booking_not_reschedulable), do: {409, "booking_not_reschedulable"}

  defp error_response(:recurring_booking_requires_manual_review),
    do: {409, "recurring_booking_requires_manual_review"}

  defp error_response(:cleaner_unavailable), do: {409, "cleaner_unavailable"}
  defp error_response(:invalid_timeslot), do: {422, "invalid_timeslot"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
