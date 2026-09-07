defmodule MithrilWeb.DirectDispatchController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectDispatch
  alias Mithril.DirectDispatchSafety

  alias MithrilWeb.Schemas.DirectDispatch.{
    AdminAssignServiceRequestRequest,
    AdminAssistedBookingRequest,
    AdminAssistedBookingResponse,
    AdminCustomerListResponse,
    AdminServiceRequestListResponse,
    AdminServiceRequestMutationResponse,
    AdminUpdateServiceRequestRequest,
    CreateServiceRequestResponse,
    ReplacementRequest,
    ServiceRequestListResponse,
    UrgentHelpRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct-dispatch"])

  operation(:list_service_requests,
    operation_id: "direct.listServiceRequests",
    summary: "List the signed-in customer's urgent-help and replacement requests",
    responses: [ok: {"Service requests", "application/json", ServiceRequestListResponse}]
  )

  def list_service_requests(conn, _params) do
    respond(conn, DirectDispatch.list_service_requests(user_id(conn)), fn requests ->
      %{requests: requests}
    end)
  end

  operation(:create_urgent_request,
    operation_id: "direct.createUrgentHelpRequest",
    summary: "Request urgent non-medical household help",
    request_body: {"Urgent help", "application/json", UrgentHelpRequest, required: true},
    responses: [ok: {"Created service request", "application/json", CreateServiceRequestResponse}]
  )

  def create_urgent_request(conn, params) do
    respond(conn, DirectDispatch.create_urgent_request(user_id(conn), params))
  end

  operation(:request_replacement,
    operation_id: "direct.requestReplacementWorker",
    summary: "Request a replacement worker for an owned paid booking",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Booking ID"
      ]
    ],
    request_body: {"Replacement request", "application/json", ReplacementRequest},
    responses: [ok: {"Created service request", "application/json", CreateServiceRequestResponse}]
  )

  def request_replacement(conn, %{"id" => id} = params) do
    respond(conn, DirectDispatchSafety.request_replacement(user_id(conn), id, params))
  end

  operation(:list_admin_customers,
    operation_id: "direct.listAdminCustomers",
    summary: "Search customers for admin-assisted booking",
    parameters: [
      q: [
        in: :query,
        schema: %Schema{type: :string, maxLength: 120},
        required: false,
        description: "Name, email, or phone search"
      ]
    ],
    responses: [ok: {"Customers", "application/json", AdminCustomerListResponse}]
  )

  def list_admin_customers(conn, params) do
    respond(conn, DirectDispatch.list_admin_customers(user_id(conn), params["q"]), fn customers ->
      %{customers: customers}
    end)
  end

  operation(:create_admin_booking,
    operation_id: "direct.createAdminAssistedBooking",
    summary: "Create a booking for a customer with recorded consent and source",
    request_body:
      {"Admin-assisted booking", "application/json", AdminAssistedBookingRequest, required: true},
    responses: [ok: {"Created booking", "application/json", AdminAssistedBookingResponse}]
  )

  def create_admin_booking(conn, params) do
    respond(conn, DirectDispatch.create_admin_booking(user_id(conn), params))
  end

  operation(:list_admin_service_requests,
    operation_id: "direct.listAdminServiceRequests",
    summary: "List urgent-help and replacement requests for dispatch operations",
    responses: [ok: {"Dispatch queue", "application/json", AdminServiceRequestListResponse}]
  )

  def list_admin_service_requests(conn, _params) do
    respond(conn, DirectDispatch.list_admin_service_requests(user_id(conn)), fn requests ->
      %{requests: requests}
    end)
  end

  operation(:assign_admin_service_request,
    operation_id: "direct.assignAdminServiceRequest",
    summary: "Assign an available vetted worker to an urgent-help or replacement request",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Service request ID"
      ]
    ],
    request_body:
      {"Worker assignment", "application/json", AdminAssignServiceRequestRequest, required: true},
    responses: [
      ok: {"Updated service request", "application/json", AdminServiceRequestMutationResponse}
    ]
  )

  def assign_admin_service_request(conn, %{"id" => id} = params) do
    respond(conn, DirectDispatchSafety.assign_admin_service_request(user_id(conn), id, params))
  end

  operation(:update_admin_service_request,
    operation_id: "direct.updateAdminServiceRequest",
    summary: "Advance or close a dispatch request",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Service request ID"
      ]
    ],
    request_body:
      {"Dispatch status", "application/json", AdminUpdateServiceRequestRequest, required: true},
    responses: [
      ok: {"Updated service request", "application/json", AdminServiceRequestMutationResponse}
    ]
  )

  def update_admin_service_request(conn, %{"id" => id} = params) do
    respond(conn, DirectDispatchSafety.update_admin_service_request(user_id(conn), id, params))
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
  defp error_response(:customer_not_found), do: {404, "customer_not_found"}
  defp error_response(:consent_required), do: {409, "consent_required"}
  defp error_response(:booking_closed), do: {409, "booking_closed"}
  defp error_response(:booking_unpaid), do: {409, "booking_unpaid"}
  defp error_response(:request_closed), do: {409, "request_closed"}
  defp error_response(:invalid_status_transition), do: {409, "invalid_status_transition"}
  defp error_response(:replacement_already_requested), do: {409, "replacement_already_requested"}
  defp error_response(:candidate_unavailable), do: {409, "candidate_unavailable"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
