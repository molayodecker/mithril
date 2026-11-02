defmodule Mithril.WhatsApp.JobOfferTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Notifications
  alias Mithril.Repo
  alias Mithril.WhatsApp.JobOffer
  alias Mithril.WhatsApp.JobOfferTemplate
  alias Mithril.WhatsApp.Recruitment

  @endpoint MithrilWeb.Endpoint
  @auth_token "test-twilio-auth-token"
  @recruitment_url "https://api.tryinstaclean.com/whatsapp/join-as-cleaner-bot"
  @worker_phone "+233200000001"
  @other_phone "+233200000099"

  setup do
    :ok = Sandbox.checkout(Repo)
    create_fixture_tables!()
    parent = self()
    previous = snapshot_env()

    Application.put_env(:mithril, :twilio_template_job_offer, "HXjoboffer")
    Application.put_env(:mithril, :twilio_http, :noop)
    Application.put_env(:mithril, :test_sms_messages, [])
    Application.delete_env(:mithril, :send_notification_url)
    Application.delete_env(:mithril, :send_notification_token)

    Application.put_env(:mithril, :job_offer_assignment, fn call ->
      send(parent, {:assignment, call})
      :ok
    end)

    Application.put_env(:mithril, :twilio_http, fn payload ->
      send(parent, {:whatsapp, payload})
      {:ok, "SMjob"}
    end)

    on_exit(fn -> restore_env(previous) end)

    {:ok, parent: parent}
  end

  test "the template button is Accept and the body has the date, time, and area" do
    definition = JobOfferTemplate.definition()
    quick_reply = definition["types"]["twilio/quick-reply"]
    [accept_button, decline_button] = quick_reply["actions"]

    assert definition["friendly_name"] == "instaclean_job_offer_accept"
    assert quick_reply["body"] =~ "{{1}}"
    assert quick_reply["body"] =~ "{{2}}"
    assert quick_reply["body"] =~ "{{3}}"
    assert String.ends_with?(quick_reply["body"], "before this offer expires.")
    refute quick_reply["body"] =~ "YES"
    assert accept_button == %{"id" => "accept_job", "title" => "Accept"}
    assert decline_button == %{"id" => "decline_job", "title" => "No"}

    assert JobOfferTemplate.variables(%{
             date: "2026-11-04",
             time: "10:00:00",
             address: "12 Independence Ave, East Legon"
           }) == %{
             "1" => "4 Nov 2026",
             "2" => "10:00",
             "3" => "East Legon"
           }

    assert JobOfferTemplate.area_label("148 Westlands Blvd") == "your area"
  end

  test "sends the Accept template once to the worker who was offered the job" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, @worker_phone)

    assert Notifications.notify(offer_context(booking_id, cleaner_id))
    assert_receive {:whatsapp, first_message}

    assert JobOffer.deliver(offer_context(booking_id, cleaner_id))
    refute_receive {:whatsapp, _}

    assert first_message.to == "whatsapp:#{@worker_phone}"
    assert first_message.content_sid == "HXjoboffer"

    assert first_message.variables == %{
             "1" => "4 Nov 2026",
             "2" => "10:00",
             "3" => "East Legon"
           }

    assert [[@worker_phone, true]] =
             Repo.query!("""
             SELECT phone, sent_at IS NOT NULL
             FROM public.whatsapp_job_offers
             WHERE status = 'open'
             """).rows

    assert [{@worker_phone, sms}] = Application.get_env(:mithril, :test_sms_messages)
    refute sms =~ "YES"
  end

  test "does not send a second prompt while this phone already has an open offer" do
    cleaner_id = Ecto.UUID.generate()
    first_booking_id = Ecto.UUID.generate()
    second_booking_id = Ecto.UUID.generate()
    insert_worker!(cleaner_id, @worker_phone)
    insert_booking!(first_booking_id, cleaner_id)
    insert_booking!(second_booking_id, cleaner_id)

    assert JobOffer.deliver(offer_context(first_booking_id, cleaner_id))
    refute JobOffer.deliver(offer_context(second_booking_id, cleaner_id))

    assert_receive {:whatsapp, _}
    refute_receive {:whatsapp, _}

    assert [[^first_booking_id]] =
             Repo.query!(
               "SELECT booking_id::text FROM public.whatsapp_job_offers WHERE status = 'open'"
             ).rows
  end

  test "does not text a blocked recipient" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, "+233535729691")

    refute JobOffer.deliver(offer_context(booking_id, cleaner_id))
    refute_receive {:whatsapp, _}

    assert Repo.query!("SELECT count(*) FROM public.whatsapp_job_offers").rows == [[0]]
  end

  test "the Accept button uses the app accept path and free text does not" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, @worker_phone)
    assert JobOffer.deliver(offer_context(booking_id, cleaner_id))
    assert_receive {:whatsapp, _}

    for body <- ["yes", "Yes.", "yes tomorrow"] do
      assert {:reply, reply} =
               JobOffer.inbound_reply(inbound(@worker_phone, body, "SM#{body}", nil))

      assert reply =~ "Tap Accept"
      refute_receive {:assignment, _}
    end

    assert {:reply, accepted} =
             JobOffer.inbound_reply(inbound(@worker_phone, "Accept", "SMaccept", "accept_job"))

    assert accepted =~ "You accepted this job"

    assert_receive {:assignment,
                    %{action: :accept, cleaner_id: ^cleaner_id, booking_id: ^booking_id}}

    assert {:reply, already} =
             JobOffer.inbound_reply(inbound(@worker_phone, "Accept", "SMaccept", "accept_job"))

    assert already =~ "You accepted this job"
    refute_receive {:assignment, _}
  end

  test "No releases the job through the app decline path" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, @worker_phone)
    assert JobOffer.deliver(offer_context(booking_id, cleaner_id))
    assert_receive {:whatsapp, _}

    assert {:reply, declined} =
             JobOffer.inbound_reply(inbound(@worker_phone, "No", "SMno", "decline_job"))

    assert declined =~ "You declined this job"

    assert_receive {:assignment,
                    %{action: :decline, cleaner_id: ^cleaner_id, booking_id: ^booking_id}}

    assert [["declined"]] =
             Repo.query!("SELECT status FROM public.whatsapp_job_offers").rows
  end

  test "a typed NO declines and any other sentence does not" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, @worker_phone)
    assert JobOffer.deliver(offer_context(booking_id, cleaner_id))
    assert_receive {:whatsapp, _}

    assert {:reply, tap} =
             JobOffer.inbound_reply(inbound(@worker_phone, "no tomorrow", "SMsentence", nil))

    assert tap =~ "Tap Accept"
    refute_receive {:assignment, _}

    assert {:reply, declined} =
             JobOffer.inbound_reply(inbound(@worker_phone, "NO", "SMtyped", nil))

    assert declined =~ "You declined this job"
    assert_receive {:assignment, %{action: :decline, booking_id: ^booking_id}}
  end

  test "an Accept from another number does not accept the job" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, @worker_phone)
    assert JobOffer.deliver(offer_context(booking_id, cleaner_id))
    assert_receive {:whatsapp, _}

    assert {:reply, reply} =
             JobOffer.inbound_reply(inbound(@other_phone, "Accept", "SMother", "accept_job"))

    assert reply =~ "no open job offer"
    refute_receive {:assignment, _}

    assert [["open"]] = Repo.query!("SELECT status FROM public.whatsapp_job_offers").rows
  end

  test "an Accept after the offer expires does not accept the job" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, @worker_phone)
    assert JobOffer.deliver(offer_context(booking_id, cleaner_id))
    assert_receive {:whatsapp, _}

    Repo.query!("""
    UPDATE public.whatsapp_job_offers
    SET expires_at = now() - interval '1 minute'
    WHERE status = 'open'
    """)

    assert {:reply, reply} =
             JobOffer.inbound_reply(inbound(@worker_phone, "Accept", "SMlate", "accept_job"))

    assert reply =~ "expired"
    refute_receive {:assignment, _}
    assert [["expired"]] = Repo.query!("SELECT status FROM public.whatsapp_job_offers").rows
  end

  test "the recruitment line answers an open offer instead of starting an application" do
    booking_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    insert_offerable_booking!(booking_id, cleaner_id, @worker_phone)
    assert JobOffer.deliver(offer_context(booking_id, cleaner_id))
    assert_receive {:whatsapp, _}

    params = recruitment_params("yes tomorrow")
    assert {:ok, xml} = Recruitment.handle_webhook(params, sign(params, @recruitment_url))
    assert xml =~ "Tap Accept"
    refute xml =~ "email"
    refute_receive {:assignment, _}
  end

  test "the job offer webhook rejects an unsigned message" do
    conn =
      post(build_conn(), "/whatsapp/job-offer", %{
        "Body" => "Accept",
        "From" => "whatsapp:#{@worker_phone}",
        "MessageSid" => "SMunsigned"
      })

    assert conn.status == 401
  end

  defp offer_context(booking_id, cleaner_id) do
    %{
      kind: :direct_assignment_offer,
      recipient: :worker,
      booking_id: booking_id,
      worker: %{user_id: cleaner_id, phone: @worker_phone, name: "Ama"},
      dates: ["2026-11-04"],
      scheduled_time: "10:00",
      address: "12 Independence Ave, East Legon"
    }
  end

  defp inbound(phone, body, message_sid, button_payload) do
    params = %{
      "From" => "whatsapp:#{phone}",
      "Body" => body,
      "MessageSid" => message_sid
    }

    if is_binary(button_payload),
      do: Map.put(params, "ButtonPayload", button_payload),
      else: params
  end

  defp recruitment_params(body) do
    %{
      "AccountSid" => "ACtestrecruitment",
      "Body" => body,
      "From" => "whatsapp:#{@worker_phone}",
      "To" => "whatsapp:+233246326939",
      "MessageSid" => "SMrecruitment"
    }
  end

  defp sign(params, url) do
    payload =
      params
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(url, fn {key, value}, acc -> acc <> key <> value end)

    :crypto.mac(:hmac, :sha, @auth_token, payload) |> Base.encode64()
  end

  defp insert_offerable_booking!(booking_id, cleaner_id, phone) do
    insert_worker!(cleaner_id, phone)
    insert_booking!(booking_id, cleaner_id)
  end

  defp insert_worker!(cleaner_id, phone) do
    Repo.query!(
      """
      INSERT INTO public.users (id, email, phone, status)
      VALUES ($1, $2, $3, 'active')
      """,
      [Ecto.UUID.dump!(cleaner_id), "cleaner-#{cleaner_id}@example.com", phone]
    )
  end

  defp insert_booking!(booking_id, cleaner_id) do
    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, cleaner_id, customer_id, assignment_phase, payment_status,
        cleaner_accepted_at, address, scheduled_date, scheduled_time,
        assignment_hold_until
      ) VALUES (
        $1, $2, $3, 'exclusive', 'paid',
        NULL, '12 Independence Ave, East Legon', $4, $5,
        now() + interval '15 minutes'
      )
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(cleaner_id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        ~D[2026-11-04],
        ~T[10:00:00]
      ]
    )
  end

  defp snapshot_env do
    [
      :twilio_template_job_offer,
      :twilio_http,
      :job_offer_assignment,
      :send_notification_url,
      :send_notification_token,
      :test_sms_messages
    ]
    |> Map.new(fn key -> {key, Application.get_env(:mithril, key)} end)
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:mithril, key)
      {key, value} -> Application.put_env(:mithril, key, value)
    end)
  end

  defp create_fixture_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate job offer fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.whatsapp_job_offer_messages CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.whatsapp_job_offers CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")
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
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      cleaner_id uuid,
      customer_id uuid,
      assignment_phase text,
      payment_status text,
      cleaner_accepted_at timestamptz,
      address text,
      scheduled_date date,
      scheduled_time time,
      assignment_hold_until timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.whatsapp_job_offers (
      id uuid PRIMARY KEY,
      booking_id uuid NOT NULL,
      cleaner_id uuid NOT NULL,
      phone text NOT NULL,
      expires_at timestamptz NOT NULL,
      status text NOT NULL DEFAULT 'open',
      sent_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX whatsapp_job_offers_one_open_booking_idx
      ON public.whatsapp_job_offers (booking_id) WHERE status = 'open'
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX whatsapp_job_offers_one_open_phone_idx
      ON public.whatsapp_job_offers (phone) WHERE status = 'open'
    """)

    Repo.query!("""
    CREATE TABLE public.whatsapp_job_offer_messages (
      message_sid text PRIMARY KEY,
      phone text NOT NULL,
      reply text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)
  end
end
