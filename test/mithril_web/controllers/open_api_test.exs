defmodule MithrilWeb.OpenApiTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint

  test "GET /openapi.json exposes the Direct API contract" do
    conn = get(build_conn(), "/openapi.json")
    spec = json_response(conn, 200)

    assert spec["openapi"] =~ "3."
    assert spec["paths"]["/direct/placements"]["get"]
    assert spec["paths"]["/direct/placements"]["post"]
    assert spec["paths"]["/direct/bookings"]["get"]
    assert spec["paths"]["/direct/bookings"]["post"]

    assert spec["paths"]["/direct/booking-categories"]["get"]["operationId"] ==
             "direct.listBookingCategories"

    refute is_binary(spec["paths"]["/direct/booking-categories"]["get"])
    assert spec["paths"]["/direct/bookings/{id}/cancel"]["post"]
    assert spec["paths"]["/direct/bookings/{id}/reschedule"]["post"]
    assert spec["paths"]["/direct/bookings/{id}/cancellation-policy"]["get"]
    assert spec["paths"]["/direct/bookings/{id}/refund-request"]["post"]
    assert spec["paths"]["/direct/admin/placements/{id}/matches"]["post"]
    assert spec["paths"]["/direct/admin/app-update-policy"]["get"]
    assert spec["paths"]["/direct/admin/app-update-policy"]["post"]
    assert spec["paths"]["/direct/admin/services"]["get"]
    assert spec["paths"]["/direct/admin/services/{id}"]["post"]
    assert spec["paths"]["/direct/admin/promotion-codes"]["get"]
    assert spec["paths"]["/direct/admin/reports/summary"]["get"]
    assert spec["paths"]["/direct/admin/service-areas"]["get"]

    assert spec["paths"]["/direct/admin/cleaners/{id}/wallet"]["get"]["operationId"] ==
             "direct.showAdminWorkerWallet"

    assert spec["paths"]["/direct/admin/cleaners/{id}/wallet-credit"]["post"]["operationId"] ==
             "direct.creditAdminWorkerWallet"

    assert spec["paths"]["/direct/worker-loans"]["get"]["operationId"] ==
             "direct.listWorkerLoanRequests"

    assert spec["paths"]["/direct/worker-loans"]["post"]["operationId"] ==
             "direct.createWorkerLoanRequest"

    assert spec["paths"]["/direct/worker-loans/summary"]["get"]["operationId"] ==
             "direct.showWorkerLoanSummary"

    assert spec["paths"]["/direct/admin/worker-loan-requests"]["get"]["operationId"] ==
             "direct.listAdminWorkerLoanRequests"

    assert spec["paths"]["/direct/admin/worker-loan-requests/{id}"]["get"]["operationId"] ==
             "direct.showAdminWorkerLoanRequest"

    assert spec["paths"]["/direct/admin/worker-loan-requests/{id}/review"]["post"]["operationId"] ==
             "direct.reviewAdminWorkerLoanRequest"

    assert spec["components"]["schemas"]["DirectAdminBooking"]["properties"][
             "loanOutstandingMinor"
           ]

    assert spec["paths"]["/direct/admin/bookings/{id}/invoice"]["get"]["operationId"] ==
             "direct.showAdminJobInvoice"

    assert spec["paths"]["/direct/admin/bookings/{id}/invoice"]["put"]["operationId"] ==
             "direct.upsertAdminJobInvoice"

    assert spec["paths"]["/direct/admin/bookings/{id}/invoice/send"]["post"]["operationId"] ==
             "direct.sendAdminJobInvoice"

    assert spec["paths"]["/direct/invoices/{token}"]["get"]["operationId"] ==
             "direct.showPublicJobInvoice"

    assert spec["paths"]["/direct/admin/billing/invoices"]["get"]["operationId"] ==
             "direct.listAdminBillingInvoices"

    assert spec["paths"]["/direct/admin/billing/invoices/{id}"]["put"]["operationId"] ==
             "direct.upsertAdminBillingInvoice"

    assert spec["paths"]["/direct/admin/billing/payment-advices"]["get"]["operationId"] ==
             "direct.listAdminPaymentAdvices"

    assert spec["paths"]["/direct/admin/billing/payment-advices/{id}"]["put"]["operationId"] ==
             "direct.upsertAdminPaymentAdvice"

    assert spec["paths"]["/direct/admin/payouts"]["get"]
    assert spec["paths"]["/direct/admin/reviews"]["get"]
    assert spec["paths"]["/direct/admin/team"]["get"]

    assert spec["paths"]["/direct/admin/accounts/merge"]["post"]["operationId"] ==
             "direct.mergeAdminAccounts"

    assert spec["paths"]["/direct/admin/team/grant"]["post"]["operationId"] ==
             "direct.grantAdminTeamRole"

    assert spec["paths"]["/direct/admin/team/revoke"]["post"]["operationId"] ==
             "direct.revokeAdminTeamRole"

    assert spec["paths"]["/direct/admin/notifications"]["get"]
    assert spec["paths"]["/direct/admin/notification-broadcast/preview"]["get"]
    assert spec["paths"]["/direct/admin/notification-broadcast"]["post"]
    assert spec["paths"]["/direct/admin/whatsapp/threads"]["get"]
    assert spec["paths"]["/direct/admin/dispatch-map"]["get"]
    assert spec["paths"]["/direct/admin/live-jobs"]["get"]
    assert spec["paths"]["/direct/admin/cleaners"]["get"]
    assert spec["paths"]["/direct/admin/cleaner-applications/{id}/approve"]["post"]
    assert spec["paths"]["/direct/admin/bookings/{id}/payment-diagnostics"]["get"]
    assert spec["components"]["schemas"]["DirectCreatePlacementRequest"]
    assert spec["components"]["schemas"]["DirectPlacementDetailResponse"]
    assert spec["components"]["schemas"]["DirectBookingListResponse"]
    assert spec["components"]["schemas"]["DirectCancelBookingResponse"]

    assert spec["components"]["schemas"]["DirectAdminAppUpdatePolicySaveRequest"]["properties"][
             "minVersion"
           ]

    assert spec["components"]["schemas"]["DirectAdminAssistedBookingRequest"]["properties"][
             "sendNotifications"
           ]

    assert spec["components"]["schemas"]["DirectAdminAssistedBookingResponse"]["properties"][
             "notificationsSent"
           ]

    assert spec["components"]["schemas"]["DirectAdminAssignServiceRequestRequest"]["properties"][
             "sendNotifications"
           ]
  end
end
