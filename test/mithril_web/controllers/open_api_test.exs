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
    assert spec["paths"]["/direct/bookings/{id}/cancel"]["post"]
    assert spec["paths"]["/direct/bookings/{id}/reschedule"]["post"]
    assert spec["paths"]["/direct/admin/placements/{id}/matches"]["post"]
    assert spec["paths"]["/direct/admin/app-update-policy"]["get"]
    assert spec["paths"]["/direct/admin/app-update-policy"]["post"]
    assert spec["paths"]["/direct/admin/notifications"]["get"]
    assert spec["paths"]["/direct/admin/notification-broadcast/preview"]["get"]
    assert spec["paths"]["/direct/admin/notification-broadcast"]["post"]
    assert spec["paths"]["/direct/admin/whatsapp/threads"]["get"]
    assert spec["paths"]["/direct/admin/dispatch-map"]["get"]
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
