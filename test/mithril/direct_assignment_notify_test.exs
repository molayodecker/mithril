defmodule Mithril.DirectAssignmentNotifyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAssignmentNotify
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_fixture_tables!()
    Application.put_env(:mithril, :test_sms_messages, [])
    previous = snapshot_notification_env()
    Application.delete_env(:mithril, :send_notification_url)
    Application.delete_env(:mithril, :send_notification_token)
    Application.delete_env(:mithril, :twilio_template_new_booking)

    on_exit(fn ->
      restore_notification_env(previous)
    end)

    :ok
  end

  test "a paid chosen worker gets one SMS and the existing inbox offer is claimed" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    insert_people!(cleaner_id, customer_id)
    insert_booking!(booking_id, cleaner_id, customer_id, "exclusive", nil)

    Repo.query!(
      """
      INSERT INTO public.notifications (id, user_id, type, title, message, read, data, created_at)
      VALUES (
        $1, $2, 'direct_assignment_offer', 'You were selected for a job',
        'Accept it in the app.', false,
        jsonb_build_object('bookingId', $3::text, 'booking_id', $3::text),
        now()
      )
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(cleaner_id),
        booking_id
      ]
    )

    assert :sent == DirectAssignmentNotify.notify_chosen_worker(booking_id)
    assert :skipped == DirectAssignmentNotify.notify_chosen_worker(booking_id)

    assert [{phone, body}] = Application.get_env(:mithril, :test_sms_messages)
    assert phone == "+233200000001"
    assert body =~ "selected"
    assert body =~ "accept"

    %{rows: [[count, outbound_sent]]} =
      Repo.query!("""
      SELECT count(*), bool_and(data->>'outbound_sent' = 'true')
      FROM public.notifications
      WHERE type = 'direct_assignment_offer'
      """)

    assert count == 1
    assert outbound_sent == true
  end

  test "inserts the in-app offer when the payment trigger did not" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    insert_people!(cleaner_id, customer_id)
    insert_booking!(booking_id, cleaner_id, customer_id, nil, nil)

    assert :sent == DirectAssignmentNotify.notify_chosen_worker(booking_id)

    %{rows: [[title, message]]} =
      Repo.query!(
        """
        SELECT title, message
        FROM public.notifications
        WHERE type = 'direct_assignment_offer'
          AND data->>'bookingId' = $1
        """,
        [booking_id]
      )

    assert title == "You were selected for a job"
    assert message =~ "Accept it in the app"
    assert [{_phone, body}] = Application.get_env(:mithril, :test_sms_messages)
    assert body =~ "accept"
  end

  test "provider failure remains retryable without duplicating the inbox offer" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    insert_people!(cleaner_id, customer_id)
    insert_booking!(booking_id, cleaner_id, customer_id, "exclusive", nil)

    previous_adapter = Application.get_env(:mithril, :sms_adapter)
    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Disabled)

    on_exit(fn ->
      Application.put_env(:mithril, :sms_adapter, previous_adapter)
    end)

    assert :failed == DirectAssignmentNotify.notify_chosen_worker(booking_id)
    assert Application.get_env(:mithril, :test_sms_messages) == []

    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Test)
    assert :sent == DirectAssignmentNotify.deliver_pending(booking_id)
    assert :skipped == DirectAssignmentNotify.deliver_pending(booking_id)

    assert [{"+233200000001", _body}] =
             Application.get_env(:mithril, :test_sms_messages)

    assert [[1, true]] =
             Repo.query!("""
             SELECT count(*), bool_and(data->>'outbound_sent' = 'true')
             FROM public.notifications
             WHERE type = 'direct_assignment_offer'
             """).rows
  end

  test "an accepted or unchosen assignment does not notify" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    insert_people!(cleaner_id, customer_id)
    insert_booking!(booking_id, cleaner_id, customer_id, "accepted", DateTime.utc_now())

    assert :skipped == DirectAssignmentNotify.notify_chosen_worker(booking_id)
    assert Application.get_env(:mithril, :test_sms_messages) == []
  end

  defp snapshot_notification_env do
    [:send_notification_url, :send_notification_token, :twilio_template_new_booking]
    |> Map.new(fn key -> {key, Application.get_env(:mithril, key)} end)
  end

  defp restore_notification_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:mithril, key)
      {key, value} -> Application.put_env(:mithril, key, value)
    end)
  end

  defp insert_people!(cleaner_id, customer_id) do
    Repo.query!(
      """
      INSERT INTO public.users (id, email, phone, status)
      VALUES ($1, 'cleaner@example.com', '+233200000001', 'active'),
             ($2, 'customer@example.com', '+233200000002', 'active')
      """,
      [Ecto.UUID.dump!(cleaner_id), Ecto.UUID.dump!(customer_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.profiles (id, fullname)
      VALUES ($1, 'Ama Cleaner'), ($2, 'Kofi Customer')
      """,
      [Ecto.UUID.dump!(cleaner_id), Ecto.UUID.dump!(customer_id)]
    )
  end

  defp insert_booking!(booking_id, cleaner_id, customer_id, phase, accepted_at) do
    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, cleaner_id, direct_assigned_cleaner_id, customer_id,
        assignment_phase, payment_status, cleaner_accepted_at,
        address, scheduled_date, scheduled_time, title
      ) VALUES (
        $1, $2, $2, $3,
        $4, 'paid', $5,
        '148 Westlands Blvd', $6, $7, 'Regular Cleaning'
      )
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(cleaner_id),
        Ecto.UUID.dump!(customer_id),
        phase,
        accepted_at,
        Date.add(Date.utc_today(), 3),
        ~T[10:00:00]
      ]
    )
  end

  defp create_fixture_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate notification fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.notifications CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.profiles CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text,
      status text NOT NULL DEFAULT 'active'
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
      cleaner_id uuid,
      direct_assigned_cleaner_id uuid,
      customer_id uuid,
      assignment_phase text,
      payment_status text,
      cleaner_accepted_at timestamptz,
      address text,
      scheduled_date date,
      scheduled_time time,
      title text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.notifications (
      id uuid PRIMARY KEY,
      user_id uuid,
      type text,
      title text,
      message text,
      read boolean DEFAULT false,
      data jsonb,
      created_at timestamptz DEFAULT now()
    )
    """)
  end
end
