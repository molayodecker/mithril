defmodule Mithril.WhatsApp.JobOffer do
  @moduledoc """
  Sends one Accept-button job offer to the worker who was just offered that
  job, and turns that button into the app's accept or decline.

  The open offer is stored against the worker's phone before the template is
  sent. It expires with `assignment_hold_until`. A missed reply is released by
  `process_direct_assignment_holds` on that same clock. Free-text "yes" does
  not accept the job. Only the Accept button payload does.
  """

  require Logger

  alias Mithril.Auth.Phone
  alias Mithril.MobileGateway
  alias Mithril.Notifications.Outbound, as: NotificationOutbound
  alias Mithril.WhatsApp.Recruitment.Outbound, as: RecruitmentOutbound
  alias Mithril.Repo
  alias Mithril.ScheduledJobs.MessageDeliveryFallback
  alias Mithril.WhatsApp.JobOfferTemplate
  alias Mithril.WhatsApp.Recruitment.Parse
  alias Mithril.WhatsApp.Recruitment.Twiml
  alias Mithril.WhatsApp.TwilioSignature

  @default_hold_seconds 15 * 60
  @gone_errors ~w(already_taken not_eligible not_found payment_not_paid not_declinable not_authenticated)

  def deliver(ctx) when is_map(ctx) do
    with booking_id when is_binary(booking_id) <- ctx[:booking_id],
         cleaner_id when is_binary(cleaner_id) <- worker_id(ctx),
         content_sid when is_binary(content_sid) <- resolve_content_sid(),
         {:ok, booking_uuid} <- Ecto.UUID.dump(booking_id),
         {:ok, cleaner_uuid} <- Ecto.UUID.dump(cleaner_id) do
      case isolate(fn -> open_and_send(booking_uuid, cleaner_uuid, content_sid) end) do
        :sent -> true
        _ -> false
      end
    else
      _ -> false
    end
  rescue
    error ->
      Logger.warning("whatsapp job offer failed: #{Exception.message(error)}")
      false
  end

  def deliver(_), do: false

  @doc """
  Handles an inbound WhatsApp message for an open job offer.

  Returns `{:reply, text}` when this number has the offer or tapped a job
  button. Returns `:pass` so another bot can handle unrelated messages.
  """
  def inbound_reply(params) when is_map(params) do
    payload = button_payload(params)
    phone = inbound_phone(params)
    message_sid = Parse.string_param(params, "MessageSid")
    body = Parse.string_param(params, "Body")

    cond do
      button_action(payload) != :invalid ->
        reply_to_button(phone, payload, message_sid)

      exact_no?(body) and is_binary(phone) and peek_open(phone) == :open ->
        reply_to_button(phone, :typed_no, message_sid)

      not is_binary(phone) ->
        :pass

      peek_open(phone) == :open ->
        {:reply, tap_reply()}

      true ->
        :pass
    end
  end

  def inbound_reply(_), do: :pass

  def handle_webhook(params, signature) when is_map(params) do
    cond do
      not webhook_configured?() ->
        {:error, :not_configured}

      not valid_signature?(params, signature) ->
        {:error, :unauthorized}

      true ->
        case inbound_reply(params) do
          {:reply, text} -> {:ok, Twiml.xml({:plain, text})}
          :pass -> {:ok, Twiml.xml(:empty)}
        end
    end
  end

  def handle_webhook(_, _), do: {:error, :not_configured}

  defp open_and_send(booking_uuid, cleaner_uuid, content_sid) do
    with :ok <- lock_key("whatsapp-job-offer-booking:" <> uuid_text(booking_uuid)),
         {:ok, preview} <- load_booking(booking_uuid, cleaner_uuid, false),
         :ok <- reject_blocked(preview.phone),
         :ok <- lock_key("whatsapp-job-offer-phone:" <> preview.phone),
         {:ok, booking} <- load_booking(booking_uuid, cleaner_uuid, true),
         :ok <- same_phone(preview.phone, booking.phone),
         :ok <- ensure_hold(booking_uuid, booking),
         {:ok, held} <- load_booking(booking_uuid, cleaner_uuid, true),
         :ok <- expire_stale_offers(),
         {:ok, offer_id} <- claim_offer(booking_uuid, held) do
      send_offer(offer_id, held, content_sid)
    else
      {:error, :already_sent} -> :sent
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp load_booking(booking_uuid, cleaner_uuid, lock_row?) do
    lock_sql = if lock_row?, do: "FOR UPDATE OF b", else: ""

    case Repo.query(
           """
           SELECT b.cleaner_id, b.assignment_hold_until, b.assignment_phase::text,
                  lower(b.payment_status::text), b.cleaner_accepted_at, b.address,
                  b.scheduled_date::text, b.scheduled_time::text, u.phone
           FROM public.bookings b
           JOIN public.users u ON u.id = b.cleaner_id
           WHERE b.id = $1
           #{lock_sql}
           """,
           [booking_uuid]
         ) do
      {:ok, %{rows: [row]}} ->
        booking = booking_from_row(row)

        cond do
          booking.cleaner_id != cleaner_uuid ->
            {:error, :not_offered}

          booking.accepted_at != nil ->
            {:error, :already_accepted}

          booking.payment_status != "paid" ->
            {:error, :not_offered}

          booking.phase not in [nil, "exclusive"] ->
            {:error, :not_offered}

          not future_hold?(booking.hold_until) and booking.hold_until != nil ->
            {:error, :expired}

          true ->
            case Phone.normalize(booking.phone || "") do
              {:ok, phone} -> {:ok, %{booking | phone: phone}}
              :error -> {:error, :no_phone}
            end
        end

      {:ok, %{rows: []}} ->
        {:error, :not_offered}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp booking_from_row([
         cleaner_id,
         hold_until,
         phase,
         payment_status,
         accepted_at,
         address,
         scheduled_date,
         scheduled_time,
         phone
       ]) do
    %{
      cleaner_id: cleaner_id,
      hold_until: hold_until,
      phase: phase,
      payment_status: payment_status,
      accepted_at: accepted_at,
      address: address || "",
      scheduled_date: scheduled_date || "",
      scheduled_time: scheduled_time || "",
      phone: phone
    }
  end

  defp ensure_hold(_booking_uuid, %{hold_until: %DateTime{}}), do: :ok
  defp ensure_hold(_booking_uuid, %{hold_until: %NaiveDateTime{}}), do: :ok

  defp ensure_hold(booking_uuid, booking) do
    hold_until = DateTime.add(DateTime.utc_now(), @default_hold_seconds, :second)

    case Repo.query(
           """
           UPDATE public.bookings
           SET assignment_hold_until = $2,
               assignment_phase = 'exclusive'
           WHERE id = $1
             AND cleaner_id = $3
             AND cleaner_accepted_at IS NULL
             AND assignment_hold_until IS NULL
           """,
           [booking_uuid, hold_until, booking.cleaner_id]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp claim_offer(booking_uuid, booking) do
    case Repo.query(
           """
           SELECT id, booking_id, sent_at
           FROM public.whatsapp_job_offers
           WHERE status = 'open' AND (booking_id = $1 OR phone = $2)
           FOR UPDATE
           """,
           [booking_uuid, booking.phone]
         ) do
      {:ok, %{rows: []}} ->
        insert_offer(booking_uuid, booking)

      {:ok, %{rows: rows}} ->
        reuse_offer(rows, booking_uuid)

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp reuse_offer(rows, booking_uuid) do
    case Enum.find(rows, fn [_id, row_booking_id, _sent_at] -> row_booking_id == booking_uuid end) do
      [_offer_id, _booking_id, sent_at] when not is_nil(sent_at) ->
        {:error, :already_sent}

      [offer_id, _booking_id, _sent_at] ->
        {:ok, offer_id}

      nil ->
        # This phone already has a different open job. Do not send another prompt.
        {:error, :phone_has_open_offer}
    end
  end

  defp insert_offer(booking_uuid, booking) do
    case Repo.transaction(fn -> insert_offer_row(booking_uuid, booking) end) do
      {:ok, offer_id} -> {:ok, offer_id}
      {:error, :phone_has_open_offer} -> {:error, :phone_has_open_offer}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_offer_row(booking_uuid, booking) do
    offer_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    hold_until =
      booking.hold_until || DateTime.add(DateTime.utc_now(), @default_hold_seconds, :second)

    case Repo.query(
           """
           INSERT INTO public.whatsapp_job_offers
             (id, booking_id, cleaner_id, phone, expires_at, status, created_at, updated_at)
           VALUES ($1, $2, $3, $4, $5, 'open', now(), now())
           """,
           [offer_id, booking_uuid, booking.cleaner_id, booking.phone, hold_until]
         ) do
      {:ok, _} ->
        offer_id

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        Repo.rollback(:phone_has_open_offer)

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp same_phone(phone, phone), do: :ok
  defp same_phone(_preview_phone, _locked_phone), do: {:error, :not_offered}

  defp send_offer(offer_id, booking, content_sid) do
    variables =
      JobOfferTemplate.variables(%{
        offer_id: uuid_text(offer_id),
        date: booking.scheduled_date,
        time: display_time_value(booking.scheduled_time),
        address: booking.address
      })

    case dispatch(booking.phone, content_sid, variables) do
      {:ok, _} ->
        mark_sent(offer_id)
        :sent

      {:error, reason} ->
        _ = expire_unsent(offer_id)

        Logger.warning(
          "whatsapp job offer provider rejected message: #{inspect(safe_reason(reason))}"
        )

        :failed
    end
  end

  defp dispatch(phone, content_sid, variables) do
    to = NotificationOutbound.whatsapp_address(phone)

    from =
      NotificationOutbound.whatsapp_address(Application.get_env(:mithril, :twilio_whatsapp_from))

    cond do
      to == nil or from == nil ->
        {:error, :not_configured}

      true ->
        case Application.get_env(:mithril, :twilio_http, :http) do
          fun when is_function(fun, 1) ->
            fun.(%{to: to, from: from, content_sid: content_sid, variables: variables})

          _ ->
            RecruitmentOutbound.send_content(to, from, content_sid, variables, nil)
        end
    end
  end

  defp mark_sent(offer_id) do
    case Repo.query(
           """
           UPDATE public.whatsapp_job_offers
           SET sent_at = now(), updated_at = now()
           WHERE id = $1
           """,
           [offer_id]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp expire_unsent(offer_id) do
    Repo.query(
      """
      UPDATE public.whatsapp_job_offers
      SET status = 'expired', updated_at = now()
      WHERE id = $1 AND sent_at IS NULL
      """,
      [offer_id]
    )
  end

  defp expire_stale_offers do
    case Repo.query("""
         UPDATE public.whatsapp_job_offers
         SET status = 'expired', updated_at = now()
         WHERE status = 'open' AND expires_at <= now()
         """) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp reply_to_button(nil, _payload, _message_sid), do: {:reply, none_reply()}

  defp reply_to_button(_phone, _payload, ""), do: {:reply, retry_reply()}

  defp reply_to_button(phone, payload, message_sid) do
    case isolate(fn -> act_on_reply(phone, payload, message_sid) end) do
      text when is_binary(text) -> {:reply, text}
      :failed -> {:reply, retry_reply()}
      other -> other
    end
  end

  defp act_on_reply(phone, payload, message_sid) do
    case preview_offer(phone, payload_offer_id(payload)) do
      %{booking_id: booking_id} ->
        with :ok <- lock_key("whatsapp-job-offer-booking:" <> uuid_text(booking_id)),
             :ok <- lock_key("whatsapp-job-offer-phone:" <> phone) do
          record_reply(phone, payload, message_sid)
        end

      nil ->
        with :ok <- lock_key("whatsapp-job-offer-phone:" <> phone) do
          record_reply(phone, payload, message_sid)
        end
    end
  end

  defp record_reply(phone, payload, message_sid) do
    case stored_reply(message_sid) do
      reply when is_binary(reply) ->
        reply

      :none ->
        text = decide(phone, payload)
        store_reply(message_sid, phone, text)
        text
    end
  end

  defp preview_offer(phone, offer_id) do
    case Repo.query(
           """
           SELECT booking_id
           FROM public.whatsapp_job_offers
           WHERE phone = $1 AND ($2::uuid IS NULL OR id = $2)
           ORDER BY created_at DESC
           LIMIT 1
           """,
           [phone, offer_id]
         ) do
      {:ok, %{rows: [[booking_id]]}} -> %{booking_id: booking_id}
      {:ok, _} -> nil
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp decide(phone, payload) do
    case lock_latest_offer(phone, payload_offer_id(payload)) do
      nil ->
        none_reply()

      %{status: "open", expired: true} = offer ->
        mark_status(offer.id, "expired")
        expired_reply()

      %{status: "accepted"} ->
        already_accepted_reply()

      %{status: "declined"} ->
        already_declined_reply()

      %{status: "expired"} ->
        expired_reply()

      offer ->
        apply_action(offer, payload)
    end
  end

  defp apply_action(offer, payload) do
    action =
      cond do
        match?({:accept, _}, button_action(payload)) -> :accept
        payload == :typed_no or match?({:decline, _}, button_action(payload)) -> :decline
        true -> :ignore
      end

    case action do
      :ignore ->
        tap_reply()

      :accept ->
        finish_action(offer, :accept, "accepted", accepted_reply())

      :decline ->
        finish_action(offer, :decline, "declined", declined_reply())
    end
  end

  defp finish_action(offer, action, status, success_reply) do
    case assignment(action, offer) do
      :ok ->
        mark_status(offer.id, status)
        success_reply

      :gone ->
        mark_status(offer.id, "expired")
        gone_reply()

      :retry ->
        retry_reply()
    end
  end

  defp assignment(action, offer) do
    cleaner_id = uuid_text(offer.cleaner_id)
    booking_id = uuid_text(offer.booking_id)

    case Application.get_env(:mithril, :job_offer_assignment, :gateway) do
      fun when is_function(fun, 1) ->
        fun.(%{action: action, cleaner_id: cleaner_id, booking_id: booking_id})

      _ ->
        gateway_assignment(action, cleaner_id, booking_id)
    end
  end

  defp gateway_assignment(action, cleaner_id, booking_id) do
    {name, args} =
      case action do
        :accept ->
          {"accept_booking_assignment", %{"p_booking_id" => booking_id}}

        :decline ->
          {"decline_booking_by_cleaner",
           %{"p_booking_id" => booking_id, "p_reason" => "Declined on WhatsApp"}}
      end

    case MobileGateway.call_rpc(cleaner_id, name, args) do
      {:ok, result} -> rpc_outcome(result)
      {:error, _} -> :retry
    end
  end

  defp rpc_outcome(%{"success" => true}), do: :ok

  defp rpc_outcome(%{"success" => false, "error" => error}) when error in @gone_errors, do: :gone

  defp rpc_outcome(%{"success" => false}), do: :retry

  defp rpc_outcome(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, map} -> rpc_outcome(map)
      _ -> :retry
    end
  end

  defp rpc_outcome(_), do: :retry

  defp lock_latest_offer(phone, offer_id) do
    case Repo.query(
           """
           SELECT id, booking_id, cleaner_id, status, (expires_at <= now())
           FROM public.whatsapp_job_offers
           WHERE phone = $1 AND ($2::uuid IS NULL OR id = $2)
           ORDER BY created_at DESC
           LIMIT 1
           FOR UPDATE
           """,
           [phone, offer_id]
         ) do
      {:ok, %{rows: [row]}} -> offer_from_row(row)
      {:ok, %{rows: []}} -> nil
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp offer_from_row([id, booking_id, cleaner_id, status, expired]) do
    %{
      id: id,
      booking_id: booking_id,
      cleaner_id: cleaner_id,
      status: status,
      expired: expired == true
    }
  end

  defp stored_reply(message_sid) do
    case Repo.query(
           "SELECT reply FROM public.whatsapp_job_offer_messages WHERE message_sid = $1",
           [message_sid]
         ) do
      {:ok, %{rows: [[reply]]}} when is_binary(reply) and reply != "" -> reply
      {:ok, _} -> :none
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp store_reply(message_sid, phone, text) do
    case Repo.query(
           """
           INSERT INTO public.whatsapp_job_offer_messages (message_sid, phone, reply)
           VALUES ($1, $2, $3)
           """,
           [message_sid, phone, text]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp mark_status(offer_id, status) do
    case Repo.query(
           """
           UPDATE public.whatsapp_job_offers
           SET status = $2, updated_at = now()
           WHERE id = $1
           """,
           [offer_id, status]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp peek_open(phone) do
    case Repo.query(
           """
           SELECT 1
           FROM public.whatsapp_job_offers
           WHERE phone = $1 AND status = 'open' AND expires_at > now()
           LIMIT 1
           """,
           [phone]
         ) do
      {:ok, %{rows: [[1]]}} ->
        :open

      {:ok, _} ->
        :none

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :none

      {:error, error} ->
        Logger.warning("whatsapp job offer lookup failed: #{inspect(safe_reason(error))}")
        :none
    end
  end

  defp isolate(fun) do
    case Repo.transaction(fn ->
           result = fun.()
           result
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.warning("whatsapp job offer stopped: #{inspect(safe_reason(reason))}")
        :failed
    end
  end

  defp lock_key(key) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [key]) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp reject_blocked(phone) do
    if MessageDeliveryFallback.blocked_recipient?(phone), do: {:error, :blocked}, else: :ok
  end

  defp future_hold?(nil), do: false

  defp future_hold?(%DateTime{} = hold_until) do
    DateTime.compare(hold_until, DateTime.utc_now()) == :gt
  end

  defp future_hold?(%NaiveDateTime{} = hold_until) do
    NaiveDateTime.compare(hold_until, NaiveDateTime.utc_now()) == :gt
  end

  defp future_hold?(_), do: false

  defp resolve_content_sid do
    if autocreate?() do
      case JobOfferTemplate.ensure() do
        {:ok, sid} when is_binary(sid) and sid != "" -> sid
        _ -> nil
      end
    else
      JobOfferTemplate.content_sid()
    end
  end

  defp autocreate? do
    Application.get_env(:mithril, :twilio_job_offer_autocreate, true)
  end

  defp worker_id(ctx) do
    worker = ctx[:worker]
    worker && (worker[:user_id] || worker["user_id"])
  end

  defp inbound_phone(params) do
    raw =
      params
      |> Parse.string_param("From")
      |> String.replace(~r/^whatsapp:/i, "")

    case Phone.normalize(raw) do
      {:ok, phone} -> phone
      :error -> nil
    end
  end

  defp button_payload(params) do
    payload = Parse.string_param(params, "ButtonPayload")
    if payload == "", do: "", else: payload
  end

  defp button_action(payload) when is_binary(payload) do
    case String.split(payload, ":", parts: 2) do
      ["accept_job", uuid] -> valid_button_uuid(:accept, uuid)
      ["decline_job", uuid] -> valid_button_uuid(:decline, uuid)
      _ -> :invalid
    end
  end

  defp button_action(_), do: :invalid

  defp valid_button_uuid(action, uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, binary} -> {action, binary}
      :error -> :invalid
    end
  end

  defp payload_offer_id(:typed_no), do: nil

  defp payload_offer_id(payload) do
    case button_action(payload) do
      {_action, uuid} -> uuid
      :invalid -> nil
    end
  end

  defp exact_no?(body) do
    normalized =
      body
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[.!?]+$/u, "")
      |> String.trim()

    normalized == "no"
  end

  defp display_time_value(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  defp display_time_value(value), do: value

  defp uuid_text(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> to_string(value)
    end
  end

  defp webhook_configured? do
    present?(Application.get_env(:mithril, :twilio_auth_token)) and
      webhook_urls() != []
  end

  defp valid_signature?(params, signature) do
    if Application.get_env(:mithril, :disable_twilio_signature_validation, false) do
      true
    else
      token = Application.get_env(:mithril, :twilio_auth_token)

      Enum.any?(webhook_urls(), fn url ->
        TwilioSignature.valid?(string_params(params), signature, token, url)
      end)
    end
  end

  defp webhook_urls do
    [
      Application.get_env(:mithril, :twilio_job_offer_webhook_url),
      Application.get_env(:mithril, :twilio_job_offer_webhook_url_alias)
    ]
    |> Enum.filter(&present?/1)
  end

  defp string_params(params) do
    params
    |> Enum.filter(fn {_key, value} ->
      is_binary(value) or is_number(value) or is_boolean(value)
    end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp tap_reply, do: "Tap Accept on the job offer to take it, or No to decline."
  defp accepted_reply, do: "You accepted this job. Open the Instaclean app for the details."
  defp declined_reply, do: "You declined this job. It can be offered to another worker."
  defp expired_reply, do: "This offer has expired."
  defp gone_reply, do: "This job is no longer available."
  defp none_reply, do: "There is no open job offer for this number."
  defp retry_reply, do: "Open the Instaclean app to respond to this job."

  defp already_accepted_reply,
    do: "You already accepted this job. Open the Instaclean app for the details."

  defp already_declined_reply, do: "You already declined this job."

  defp safe_reason(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :error
end
