defmodule Mithril.ScheduledJobs.CleanupOrphanedQuickTaskUploadsTest do
  use ExUnit.Case, async: true

  alias Mithril.ScheduledJobs.CleanupOrphanedQuickTaskUploads

  test "orphaned upload cleanup uses a 24 hour interval, not a text duration" do
    interval = CleanupOrphanedQuickTaskUploads.older_than_interval()

    assert %Postgrex.Interval{months: 0, days: 0, secs: 86_400, microsecs: 0} = interval
    refute is_binary(interval)
  end
end
