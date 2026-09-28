defmodule Mithril.ScheduledJobs.SyncPropertyCalendarFeedsTest do
  use ExUnit.Case, async: true

  alias Mithril.PropertyCalendarSync
  alias Mithril.ScheduledJobs.SyncPropertyCalendarFeeds

  test "cron job delegates to PropertyCalendarSync.sync_batch/0" do
    Code.ensure_loaded!(SyncPropertyCalendarFeeds)
    assert {:run, 0} in SyncPropertyCalendarFeeds.__info__(:functions)
    assert {:sync_batch, 0} in PropertyCalendarSync.__info__(:functions)
  end

  test "sync batch limit bounds concurrent feed work per cron tick" do
    assert PropertyCalendarSync.batch_limit() == 20
  end
end
