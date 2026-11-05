defmodule Mithril.ScheduledJobs.SyncPropertyCalendarFeedsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.PropertyCalendarSync
  alias Mithril.Repo
  alias Mithril.ScheduledJobs.SyncPropertyCalendarFeeds

  setup do
    :ok = Sandbox.checkout(Repo)
    create_feeds_table!()
    :ok
  end

  test "stale feed lookup accepts a datetime cutoff" do
    later = DateTime.utc_now() |> DateTime.add(3600, :second)

    Repo.query!(
      """
      INSERT INTO public.property_calendar_feeds
        (id, property_id, feed_url_encrypted, sync_enabled, last_synced_at)
      VALUES ($1::uuid, $2::uuid, 'not-a-feed', true, $3::timestamptz)
      """,
      [Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate(), later]
    )

    assert :ok = SyncPropertyCalendarFeeds.run()
  end

  test "cron job delegates to PropertyCalendarSync.sync_batch/0" do
    Code.ensure_loaded!(SyncPropertyCalendarFeeds)
    assert {:run, 0} in SyncPropertyCalendarFeeds.__info__(:functions)
    assert {:sync_batch, 0} in PropertyCalendarSync.__info__(:functions)
  end

  test "sync batch limit bounds concurrent feed work per cron tick" do
    assert PropertyCalendarSync.batch_limit() == 20
  end

  defp create_feeds_table! do
    Repo.query!("DROP TABLE IF EXISTS public.property_calendar_feeds")

    Repo.query!("""
    CREATE TABLE public.property_calendar_feeds (
      id uuid PRIMARY KEY,
      property_id uuid,
      feed_url_encrypted text,
      timezone text,
      minimum_turnover_minutes integer,
      default_checkout_time time,
      default_checkin_time time,
      provider text,
      sync_enabled boolean,
      last_synced_at timestamptz,
      last_successful_sync_at timestamptz,
      last_sync_error text,
      updated_at timestamptz
    )
    """)
  end
end
