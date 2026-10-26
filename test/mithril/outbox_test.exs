defmodule Mithril.OutboxTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Notifications.InboxPush
  alias Mithril.Outbox
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_fixture_tables!()
    previous_adapter = Application.get_env(:mithril, :paystack_adapter)
    Application.put_env(:mithril, :paystack_adapter, Mithril.Paystack.Test)

    on_exit(fn ->
      Application.put_env(:mithril, :paystack_adapter, previous_adapter)
    end)

    :ok
  end

  test "offer pushes use the job-offer sound, channel, and cleaner audience" do
    assert InboxPush.sound("direct_assignment_offer") == "instaclean_job_offer.wav"
    assert InboxPush.channel("direct_assignment_offer", 3) == "job_offers_v3"
    assert InboxPush.channel("direct_assignment_offer", 1) == "job_offers_v2"
    assert InboxPush.channel("booking_confirmation", nil) == "booking_updates"
    assert InboxPush.interruption_level("direct_assignment_offer") == "time-sensitive"
  end

  test "drains an inbox push through the injected sender" do
    user_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.mithril_outbox (kind, dedupe_key, payload)
      VALUES (
        'inbox_push',
        'offer-1',
        jsonb_build_object(
          'user_id', $1::text,
          'title', 'You were selected for a job',
          'body', 'Accept it in the app.',
          'type', 'direct_assignment_offer',
          'data', jsonb_build_object('bookingId', 'booking-1', 'type', 'direct_assignment_offer')
        )
      )
      """,
      [user_id]
    )

    assert :ok ==
             Outbox.drain(
               tokens: [%{token: "ExponentPushToken[test-token]", channel_version: 3}],
               push: fn tokens, payload ->
                 send(self(), {:push, tokens, payload})
                 1
               end
             )

    assert_receive {:push, ["ExponentPushToken[test-token]"], payload}
    assert payload.title == "You were selected for a job"
    assert payload.sound == "instaclean_job_offer.wav"
    assert payload.channel_id == "job_offers_v3"
    assert payload.data["audience"] == "worker"

    assert [[status]] =
             Repo.query!("SELECT status FROM public.mithril_outbox").rows

    assert status == "sent"
  end

  test "a new message push names the conversation and records the inbox row" do
    customer_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.conversations (id, customer_id, cleaner_id)
      VALUES ($1, $2, $3)
      """,
      [
        Ecto.UUID.dump!(conversation_id),
        Ecto.UUID.dump!(customer_id),
        Ecto.UUID.dump!(cleaner_id)
      ]
    )

    Repo.query!(
      """
      INSERT INTO public.messages (id, conversation_id, sender_id, content)
      VALUES ($1, $2, $3, 'The gate code is 1234')
      """,
      [
        Ecto.UUID.dump!(message_id),
        Ecto.UUID.dump!(conversation_id),
        Ecto.UUID.dump!(customer_id)
      ]
    )

    Repo.query!(
      """
      INSERT INTO public.mithril_outbox (kind, dedupe_key, payload)
      VALUES ('new_message', $1, jsonb_build_object('message_id', $1::text))
      """,
      [message_id]
    )

    assert :ok ==
             Outbox.drain(
               tokens: ["ExponentPushToken[message-token]"],
               push: fn tokens, payload ->
                 send(self(), {:push, tokens, payload})
                 1
               end
             )

    assert_receive {:push, ["ExponentPushToken[message-token]"], payload}
    assert payload.data["type"] == "new_message"
    assert payload.data["conversationId"] == conversation_id
    assert payload.channel_id == "messages"

    assert [[recipient_id, dedupe_key]] =
             Repo.query!("SELECT user_id::text, dedupe_key FROM public.notifications").rows

    assert recipient_id == cleaner_id
    assert dedupe_key == "new_message:" <> message_id
  end

  test "verification creates a Paystack customer through the Mithril adapter" do
    user_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.users (id, email, phone)
      VALUES ($1, 'worker@example.com', '+233200000001')
      """,
      [Ecto.UUID.dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.profiles (id, firstname, lastname)
      VALUES ($1, 'Ama', 'Cleaner')
      """,
      [Ecto.UUID.dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.cleaner_data (user_id, verified, paystack_customer_id)
      VALUES ($1, true, NULL)
      """,
      [Ecto.UUID.dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.mithril_outbox (kind, dedupe_key, payload)
      VALUES ('paystack_customer', $1, jsonb_build_object('user_id', $1::text))
      """,
      [user_id]
    )

    assert :ok == Outbox.drain()

    assert [["CUS_test"]] =
             Repo.query!("SELECT paystack_customer_id FROM public.cleaner_data").rows

    assert [["sent"]] = Repo.query!("SELECT status FROM public.mithril_outbox").rows
  end

  defp create_fixture_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate outbox fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.mithril_outbox CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.notifications CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.messages CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.conversations CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.cleaner_data CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.profiles CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")

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
      firstname text,
      lastname text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY,
      verified boolean,
      paystack_customer_id text,
      updated_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.conversations (
      id uuid PRIMARY KEY,
      customer_id uuid,
      cleaner_id uuid
    )
    """)

    Repo.query!("""
    CREATE TABLE public.messages (
      id uuid PRIMARY KEY,
      conversation_id uuid,
      sender_id uuid,
      content text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.notifications (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid,
      type text,
      title text,
      message text,
      read boolean DEFAULT false,
      data jsonb,
      dedupe_key text,
      created_at timestamptz DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX notifications_user_dedupe_key_uniq
      ON public.notifications (user_id, dedupe_key)
      WHERE dedupe_key IS NOT NULL
    """)

    Repo.query!("""
    CREATE TABLE public.mithril_outbox (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      kind text NOT NULL,
      dedupe_key text NOT NULL,
      payload jsonb NOT NULL DEFAULT '{}'::jsonb,
      status text NOT NULL DEFAULT 'pending',
      attempts integer NOT NULL DEFAULT 0,
      last_error text,
      available_at timestamptz NOT NULL DEFAULT now(),
      claimed_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      sent_at timestamptz,
      UNIQUE (kind, dedupe_key)
    )
    """)
  end
end
