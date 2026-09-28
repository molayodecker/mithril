defmodule Mithril.ScheduledJobsTest do
  use ExUnit.Case, async: true

  alias Mithril.ScheduledJobs

  test "native jobs are registered" do
    for name <- [
          "booking-ops-reminders",
          "retry-payment-failure-ops-alerts",
          "booking-customer-reminders",
          "sync-property-calendar-feeds",
          "admin-broadcast-worker"
        ] do
      assert name in ScheduledJobs.native_job_names()
    end
  end

  test "unknown job returns error" do
    assert {:error, {:unknown_scheduled_job, "not-a-job"}} = ScheduledJobs.run("not-a-job")
  end
end
