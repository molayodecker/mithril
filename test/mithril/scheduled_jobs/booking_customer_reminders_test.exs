defmodule Mithril.ScheduledJobs.BookingCustomerRemindersTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.ScheduledJobs.BookingCustomerReminders

  setup do
    :ok = Sandbox.checkout(Repo)
    create_reminder_tables!()
    :ok
  end

  test "selects reminder candidates with date parameters" do
    assert :ok = BookingCustomerReminders.run()
  end

  defp create_reminder_tables! do
    Repo.query!("DROP TABLE IF EXISTS public.direct_booking_origins")
    Repo.query!("DROP TABLE IF EXISTS public.bookings")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid,
      cleaner_id uuid,
      customer_contact_phone text,
      title text,
      scheduled_date date,
      scheduled_time time,
      address text,
      status text,
      payment_status text,
      schedule_group_id uuid,
      subscription_id uuid,
      recurrence_interval text,
      customer_reminder_7d_sent_at timestamptz,
      customer_reminder_7d_claimed_at timestamptz,
      customer_reminder_48h_sent_at timestamptz,
      customer_reminder_48h_claimed_at timestamptz,
      customer_reminder_sent_at timestamptz,
      cleaner_reminder_sent_at timestamptz,
      customer_reminder_claimed_at timestamptz,
      cleaner_reminder_claimed_at timestamptz,
      customer_reminder_morning_sent_at timestamptz,
      customer_reminder_morning_claimed_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.direct_booking_origins (
      booking_id uuid PRIMARY KEY
    )
    """)
  end
end
