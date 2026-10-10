defmodule Mithril.Cron.Jobs do
  @moduledoc """
  Oban cron inventory mirrored from Supabase project `jzevawnetjwnliamyilb`
  (`cron.job` as of 2026-09-28).

  Refresh the remote list:

      cd instaclean && supabase db query --linked \\
        "SELECT jobname, schedule FROM cron.job ORDER BY jobname;"

  After Mithril runs these jobs reliably, unschedule the matching `pg_cron` rows
  on Supabase so work is not duplicated.
  """

  @project_ref "jzevawnetjwnliamyilb"

  @sql_jobs [
    {"*/15 * * * *", "auth_lookup_rate_limit_prune"},
    {"0 * * * *", "auto-close-stale-bookings"},
    {"*/10 * * * *", "broadcast-unassigned-paid-bookings"},
    {"*/15 * * * *", "cleanup-expired-welcome-promo-reservations"},
    {"*/5 * * * *", "escalate-unassigned-paid-bookings-past-grace"},
    {"0 * * * *", "expire_stale_pending_bookings_job"},
    {"*/5 * * * *", "process-direct-assignment-holds"},
    {"15 5 * * *", "refresh_cleaner_health_snapshots"},
    {"*/5 * * * *", "release_cleaner_hold_15min"}
  ]

  @scheduled_jobs [
    {"30 * * * *", "admin-broadcast-worker"},
    {"0 * * * *", "booking-customer-reminders"},
    {"*/15 * * * *", "booking-ops-reminders"},
    {"15 * * * *", "booking-review-requests"},
    {"15 * * * *", "charge-managed-subscription-renewals"},
    {"* * * * *", "cleaner-wallet-credit-notifications"},
    {"0 0 * * *", "cleaner-application-ops-reminders"},
    {"20 * * * *", "cleanup-expired-cleaning-scan-media"},
    {"20 3 * * *", "cleanup-orphaned-quick-task-uploads"},
    {"0 3 * * *", "cleanup-stale-ghana-card-uploads-daily"},
    {"*/2 * * * *", "message-delivery-fallback"},
    {"*/5 * * * *", "retry-payment-failure-ops-alerts"},
    {"30 * * * *", "sync-property-calendar-feeds"}
  ]

  @spec project_ref() :: String.t()
  def project_ref, do: @project_ref

  @spec oban_crontab() :: [{String.t(), module(), keyword()}]
  def oban_crontab do
    mithril_only =
      Enum.map(mithril_only_jobs(), fn {schedule, worker, opts} ->
        {schedule, worker, opts}
      end)

    sql =
      Enum.map(@sql_jobs, fn {schedule, name} ->
        {schedule, Mithril.Workers.DatabaseCron, args: %{name: name}}
      end)

    scheduled =
      Enum.map(@scheduled_jobs, fn {schedule, name} ->
        {schedule, Mithril.Workers.ScheduledJob, args: %{name: name}}
      end)

    mithril_only ++ sql ++ scheduled
  end

  @spec mithril_only_jobs() :: [{String.t(), module(), keyword()}]
  def mithril_only_jobs do
    [
      {"0 * * * *", Mithril.Workers.BookingReminderSweep, []}
    ]
  end

  @spec sql_job_names() :: [String.t()]
  def sql_job_names, do: Enum.map(@sql_jobs, fn {_schedule, name} -> name end)

  @spec scheduled_job_names() :: [String.t()]
  def scheduled_job_names, do: Enum.map(@scheduled_jobs, fn {_schedule, name} -> name end)
end
