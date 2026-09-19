defmodule Mithril.Notifications.RemindersSendTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Notifications.Reminders
  alias Mithril.Repo
  alias Mithril.Workers.BookingReminder

  setup do
    :ok = Sandbox.checkout(Repo)
    Application.put_env(:mithril, :test_sms_messages, [])
    recreate_tables()
    :ok
  end

  test "sends the customer 24h reminder and stamps the booking" do
    ids = insert_concierge_booking!(hours_from_now: 24)

    assert :ok = Reminders.send_stage(ids.booking_id, "customer_24h")

    phones = Application.get_env(:mithril, :test_sms_messages) |> Enum.map(&elem(&1, 0))
    assert phones == [ids.customer_phone]

    [[sent_at]] =
      Repo.query!(
        "SELECT customer_reminder_sent_at FROM public.bookings WHERE id = $1",
        [Ecto.UUID.dump!(ids.booking_id)]
      ).rows

    assert sent_at
  end

  test "does not send the same stage twice" do
    ids = insert_concierge_booking!(hours_from_now: 24)

    assert :ok = Reminders.send_stage(ids.booking_id, "customer_24h")
    assert :discard = Reminders.send_stage(ids.booking_id, "customer_24h")
    assert length(Application.get_env(:mithril, :test_sms_messages)) == 1
  end

  test "discards reminders outside the window" do
    ids = insert_concierge_booking!(hours_from_now: 12)

    assert :discard = Reminders.send_stage(ids.booking_id, "customer_24h")
    assert Application.get_env(:mithril, :test_sms_messages) == []
  end

  test "worker maps already-claimed to discard" do
    job = %Oban.Job{args: %{"booking_id" => Ecto.UUID.generate(), "stage" => "customer_24h"}}
    assert :discard = BookingReminder.perform(job)
  end

  defp insert_concierge_booking!(hours_from_now: hours) do
    customer_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()
    admin_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()
    scheduled = DateTime.add(DateTime.utc_now(), hours * 3600, :second)
    date = DateTime.to_date(scheduled)
    time = DateTime.to_time(scheduled) |> Time.truncate(:second)

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(customer_id),
      "ama@example.com",
      "+233555000001"
    ])

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(worker_id),
      "kojo@example.com",
      "+233555000002"
    ])

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(admin_id),
      "ops@example.com",
      "+233555000003"
    ])

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, cleaner_id, service_id, address, scheduled_date, scheduled_time,
        duration_hours, status, payment_status
      ) VALUES ($1, $2, $3, 1, 'East Legon', $4, $5, 3, 'pending', 'pending')
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(customer_id),
        Ecto.UUID.dump!(worker_id),
        date,
        time
      ]
    )

    Repo.query!(
      """
      INSERT INTO public.direct_booking_origins (
        booking_id, customer_id, created_by_user_id, source, consent_confirmed
      ) VALUES ($1, $2, $3, 'phone', true)
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), Ecto.UUID.dump!(admin_id)]
    )

    %{booking_id: booking_id, customer_phone: "+233555000001"}
  end

  defp recreate_tables do
    for table <- ~w(direct_booking_origins bookings profiles users) do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      lastname text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      service_id integer NOT NULL,
      address text NOT NULL,
      scheduled_date date NOT NULL,
      scheduled_time time NOT NULL,
      duration_hours numeric NOT NULL,
      status text NOT NULL,
      payment_status text NOT NULL,
      recurrence_interval text,
      customer_reminder_7d_sent_at timestamptz,
      customer_reminder_7d_claimed_at timestamptz,
      customer_reminder_48h_sent_at timestamptz,
      customer_reminder_48h_claimed_at timestamptz,
      customer_reminder_sent_at timestamptz,
      customer_reminder_claimed_at timestamptz,
      customer_reminder_morning_sent_at timestamptz,
      customer_reminder_morning_claimed_at timestamptz,
      cleaner_reminder_sent_at timestamptz,
      cleaner_reminder_claimed_at timestamptz,
      customer_reminder_last_error text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.direct_booking_origins (
      booking_id uuid PRIMARY KEY REFERENCES public.bookings(id),
      customer_id uuid NOT NULL,
      created_by_user_id uuid NOT NULL,
      source text NOT NULL,
      consent_confirmed boolean NOT NULL DEFAULT true
    )
    """)
  end
end
