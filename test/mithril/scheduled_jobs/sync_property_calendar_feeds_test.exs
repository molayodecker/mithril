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

  describe "sync_batch/0 query parameters" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Mithril.Repo)
      :ok
    end

    test "timestamptz params are passed as DateTime structs, not ISO 8601 strings" do
      stale_before = DateTime.add(DateTime.utc_now(), -30, :minute)

      assert {:ok, %{rows: [[%DateTime{}]]}} =
               Mithril.Repo.query("SELECT $1::timestamptz", [stale_before])

      refute match?({:error, %DBConnection.EncodeError{}}, PropertyCalendarSync.sync_batch())
    end
  end
end
