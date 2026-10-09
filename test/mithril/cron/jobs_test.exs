defmodule Mithril.Cron.JobsTest do
  use ExUnit.Case, async: true

  alias Mithril.Cron.Jobs
  alias Mithril.ScheduledJobs
  alias Mithril.Workers.{DatabaseCron, ScheduledJob}

  test "every imported SQL cron name maps to a DatabaseCron statement" do
    for name <- Jobs.sql_job_names() do
      assert is_binary(DatabaseCron.statement(name)), "missing SQL for #{name}"
    end
  end

  test "every imported scheduled job name is native in Mithril" do
    for name <- Jobs.scheduled_job_names() do
      assert name in ScheduledJobs.native_job_names()
    end
  end

  test "oban crontab covers jzevawnetjwnliamyilb inventory" do
    assert length(Jobs.sql_job_names()) == 9
    assert length(Jobs.scheduled_job_names()) == 13

    crontab = Jobs.oban_crontab()
    assert length(crontab) == 23

    assert Enum.any?(crontab, fn {_schedule, worker, _opts} ->
             worker == ScheduledJob
           end)

    assert Enum.any?(crontab, fn {_schedule, worker, _opts} ->
             worker == DatabaseCron
           end)
  end
end
