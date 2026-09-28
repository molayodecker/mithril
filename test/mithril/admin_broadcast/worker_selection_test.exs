defmodule Mithril.AdminBroadcast.WorkerSelectionTest do
  use ExUnit.Case, async: true

  alias Mithril.AdminBroadcast.WorkerSelection

  test "only worker delivery mode with queued or sending is pickable" do
    assert WorkerSelection.eligible_for_worker_pickup?("worker", "queued")
    assert WorkerSelection.eligible_for_worker_pickup?("worker", "sending")
    refute WorkerSelection.eligible_for_worker_pickup?("worker", "completed")
    refute WorkerSelection.eligible_for_worker_pickup?("worker", "failed")
    refute WorkerSelection.eligible_for_worker_pickup?("immediate", "queued")
  end

  test "completed broadcasts are terminal and not pickable" do
    assert WorkerSelection.terminal_status?("completed")
    assert WorkerSelection.terminal_status?("failed")
    refute WorkerSelection.pickable_status?("completed")
  end
end
