defmodule Mithril.ScheduledJobs.ChargeManagedSubscriptionRenewalsTest do
  use ExUnit.Case, async: true

  @renewals_source Path.expand(
                     "../../lib/mithril/scheduled_jobs/charge_managed_subscription_renewals.ex",
                     __DIR__
                   )

  test "renewal booking insert stores extra_task_ids as text slugs, not uuid[]" do
    source = File.read!(@renewals_source)

    assert source =~ "COALESCE($11::text[], '{}')",
           "expected renewal INSERT to cast subscription extra_task_ids as text[]"

    refute source =~ "COALESCE($11::uuid[], '{}')",
           "uuid[] cast breaks slug ids such as fridge or oven"
  end
end
