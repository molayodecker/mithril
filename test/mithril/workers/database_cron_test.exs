defmodule Mithril.Workers.DatabaseCronTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.Cron.Jobs
  alias Mithril.Workers.DatabaseCron

  test "each scheduled name maps to one SQL statement" do
    entries = scheduled_database_cron_entries()
    assert length(entries) == length(Jobs.sql_job_names())

    for {_schedule, DatabaseCron, opts} <- entries do
      assert is_binary(DatabaseCron.statement(opts[:args].name))
    end
  end

  test "expire_stale_pending_bookings is scheduled hourly" do
    assert {"0 * * * *", DatabaseCron, opts} =
             Enum.find(scheduled_database_cron_entries(), fn {_schedule, _mod, opts} ->
               opts[:args].name == "expire_stale_pending_bookings_job"
             end)

    assert DatabaseCron.statement(opts[:args].name) ==
             "SELECT public.expire_stale_pending_bookings()"
  end

  test "an unknown job name is discarded" do
    assert DatabaseCron.perform(%Oban.Job{args: %{"name" => "not-imported"}}) == :discard
  end

  test "expires only unpaid pending bookings older than 48 hours" do
    :ok = Sandbox.checkout(Repo)
    create_expire_schema!()

    stale_unpaid = insert_booking!("pending", "pending", hours_ago: 50)
    recent_unpaid = insert_booking!("pending", "pending", hours_ago: 12)
    stale_paid = insert_booking!("pending", "paid", hours_ago: 50)
    stale_scheduled = insert_booking!("scheduled", "pending", hours_ago: 50)
    stale_subscription = insert_booking!("pending", "pending", hours_ago: 50, subscription: true)

    assert :ok =
             DatabaseCron.perform(%Oban.Job{
               args: %{"name" => "expire_stale_pending_bookings_job"}
             })

    assert status(stale_unpaid) == "cancelled"
    assert status(recent_unpaid) == "pending"
    assert status(stale_paid) == "pending"
    assert status(stale_scheduled) == "scheduled"
    assert status(stale_subscription) == "pending"
  end

  test "does not cancel a booking that is being updated inside the 48 hour window" do
    :ok = Sandbox.checkout(Repo)
    create_expire_schema!()

    booking_id = insert_booking!("pending", "pending", hours_ago: 50)

    Repo.query!(
      "UPDATE public.bookings SET updated_at = now() - interval '1 hour' WHERE id = $1",
      [booking_id]
    )

    assert :ok =
             DatabaseCron.perform(%Oban.Job{
               args: %{"name" => "expire_stale_pending_bookings_job"}
             })

    assert status(booking_id) == "pending"
  end

  defp scheduled_database_cron_entries do
    Jobs.oban_crontab()
    |> Enum.filter(fn
      {_schedule, DatabaseCron, _opts} -> true
      _entry -> false
    end)
  end

  defp create_expire_schema! do
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")
    Repo.query!("DROP FUNCTION IF EXISTS public.expire_stale_pending_bookings()")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id uuid NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      payment_status text NOT NULL DEFAULT 'pending',
      subscription_id uuid,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE FUNCTION public.expire_stale_pending_bookings()
    RETURNS integer
    LANGUAGE plpgsql
    AS $$
    DECLARE
      affected integer;
      v_now timestamptz := now();
    BEGIN
      UPDATE public.bookings
      SET
        status = 'cancelled',
        updated_at = v_now
      WHERE status = 'pending'
        AND payment_status = 'pending'
        AND subscription_id IS NULL
        AND created_at < (v_now - interval '48 hours')
        AND updated_at < (v_now - interval '48 hours');

      GET DIAGNOSTICS affected = ROW_COUNT;
      RETURN affected;
    END;
    $$
    """)
  end

  defp insert_booking!(status, payment_status, opts) do
    hours_ago = Keyword.fetch!(opts, :hours_ago)

    subscription_id =
      if Keyword.get(opts, :subscription), do: Ecto.UUID.dump!(Ecto.UUID.generate())

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO public.bookings (
          customer_id, status, payment_status, subscription_id, created_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, now() - ($5 * interval '1 hour'), now() - ($5 * interval '1 hour')
        )
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          status,
          payment_status,
          subscription_id,
          hours_ago
        ]
      )

    id
  end

  defp status(id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM public.bookings WHERE id = $1", [id])

    status
  end
end
