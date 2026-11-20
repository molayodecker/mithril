defmodule Mithril.WhatsApp.BookingOffer do
  @moduledoc false

  alias Mithril.Auth
  alias Mithril.Auth.Phone
  alias Mithril.DirectAdminWhatsApp
  alias Mithril.DirectBookings
  alias Mithril.Repo
  alias Mithril.WhatsApp.ContentTemplate
  alias Mithril.WhatsApp.Recruitment.Parse
  alias Mithril.WhatsApp.Recruitment.Twiml
  alias Mithril.WhatsApp.TwilioSignature

  @timezone "Africa/Accra"
  @openai_url "https://api.openai.com/v1/chat/completions"
  @template_key "whatsapp_booking_offer_v1"

  def inbound_reply(params) when is_map(params) do
    phone = inbound_phone(params)

    if is_binary(phone) and open_offer?(phone) do
      {:reply,
       reply_for(
         phone,
         Parse.string_param(params, "Body"),
         button_payload(params),
         Parse.string_param(params, "MessageSid")
       )}
    else
      :pass
    end
  end

  def inbound_reply(_params), do: :pass

  def handle_webhook(params, signature) when is_map(params) do
    with :ok <- verify(params, signature),
         phone when is_binary(phone) <- inbound_phone(params) do
      reply =
        reply_for(
          phone,
          Parse.string_param(params, "Body"),
          button_payload(params),
          Parse.string_param(params, "MessageSid")
        )

      {:ok, Twiml.xml({:plain, reply})}
    else
      :unauthorized -> {:error, :unauthorized}
      :not_configured -> {:error, :not_configured}
      _ -> {:ok, Twiml.xml(:empty)}
    end
  end

  def start(user_id, params) when is_map(params) do
    with {:ok, admin_id} <- required_uuid(user_id),
         :ok <- require_admin(admin_id),
         {:ok, input} <- validate_start(params),
         {:ok, customer} <- load_customer(input.customer_id),
         {:ok, service_name} <- load_service(input.service_id),
         :ok <- no_open_offer(customer.phone),
         {:ok, offer} <- insert_offer(admin_id, customer, service_name, input),
         {:ok, sid} <- content_sid(),
         :ok <- send_offer(admin_id, offer, sid) do
      {:ok, public_offer(offer)}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch(user_id, phone) do
    with {:ok, admin_id} <- required_uuid(user_id),
         :ok <- require_admin(admin_id),
         {:ok, e164} <- Phone.normalize(to_string(phone)),
         {:ok, offer} <- load_latest(e164) do
      {:ok, public_offer(offer)}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def accept(user_id, offer_id) do
    with {:ok, admin_id} <- required_uuid(user_id),
         :ok <- require_admin(admin_id),
         {:ok, offer} <- load_by_id(offer_id),
         {:ok, updated, facts} <- apply_choice(offer, :book, today()) do
      {:ok, Map.put(public_offer(updated), :reply, phrase(updated, "Book", facts))}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def schedule(user_id, offer_id, params) when is_map(params) do
    with {:ok, admin_id} <- required_uuid(user_id),
         :ok <- require_admin(admin_id),
         {:ok, date} <- iso_date(params["scheduledDate"] || params[:scheduledDate]),
         {:ok, time} <- iso_time(params["scheduledTime"] || params[:scheduledTime]),
         :ok <- future_slot(date, today()),
         {:ok, offer} <- load_by_id(offer_id),
         {:ok, updated, facts} <- apply_choice(offer, {:schedule, date, time}, today()) do
      {:ok, Map.put(public_offer(updated), :reply, phrase(updated, "", facts))}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def visit_slots(%Date{} = today) do
    Enum.map(1..3, fn offset ->
      date = Date.add(today, offset)

      %{
        index: offset,
        date: Date.to_iso8601(date),
        time: "09:00",
        label: "#{offset}. #{weekday(date)} #{date.day} #{month(date)} at 09:00"
      }
    end)
  end

  @doc false
  def interpret(status, body, payload, %Date{} = today) when is_binary(status) do
    decide(
      %{status: status, service_name: "Cleaning", amount_minor: 15_000, currency: "GHS"},
      body,
      payload,
      today
    )
  end

  @doc false
  def choice(status, body, payload, %Date{} = today) when is_binary(status) do
    text = to_string(body)
    button = to_string(payload)

    cond do
      status == "offered" and (book_button?(button) or book_word?(text)) ->
        :book

      status == "awaiting_time" ->
        case schedule_from_text(text, today) do
          nil -> :unknown
          slot -> {:schedule, slot.date, slot.time}
        end

      true ->
        :unknown
    end
  end

  @doc false
  def stock_reply(facts) when is_map(facts) do
    case facts.event do
      "awaiting_time" ->
        lines = Enum.map_join(facts.slots, "\n", & &1.label)

        "Your #{facts.service} is reserved for #{facts.amount}. When would you like it?\n#{lines}\nOr send your own date and time, for example Friday at 2pm."

      "assigned" ->
        "#{facts.cleaner} is booked for your #{facts.service} on #{facts.when} at #{facts.address}. The price is #{facts.amount}."

      "clarify" ->
        lines = Enum.map_join(facts.slots, "\n", & &1.label)

        "I still need a day and a time.\n#{lines}\nYou can also type your own, such as 22 Nov at 14:00."

      "no_cleaner" ->
        lines = Enum.map_join(facts.slots, "\n", & &1.label)

        "Nobody is free at that time. Send another day and time, or choose one of these:\n#{lines}"

      _ ->
        "Tap Book on the message we sent and I will ask when you would like the visit."
    end
  end

  defp reply_for(phone, body, payload, message_sid) do
    with nil <- stored_reply(message_sid),
         {:ok, offer} <- load_latest(phone) do
      decision = decide(offer, body, payload, today())

      case apply_choice(offer, decision, today()) do
        {:ok, updated, facts} ->
          text = phrase(updated, body, facts)
          remember_reply(message_sid, phone, text)
          remember_inbox(phone, text)
          text

        {:error, reason} ->
          text =
            stock_reply(%{
              event: error_event(reason, offer.status),
              service: offer.service_name,
              amount: money(offer.amount_minor, offer.currency),
              slots: visit_slots(today())
            })

          remember_reply(message_sid, phone, text)
          remember_inbox(phone, text)
          text
      end
    else
      reply when is_binary(reply) ->
        reply

      {:error, :not_found} ->
        "There is no open Instaclean visit on this number. Ask us to send a booking offer."

      _ ->
        "I could not read that. Please try again in a moment."
    end
  end

  defp decide(offer, body, payload, today) do
    case choice(offer.status, body, payload, today) do
      :unknown -> model_choice(offer, body, today)
      chosen -> chosen
    end
  end

  defp model_choice(offer, body, today) do
    slots = visit_slots(today)

    prompt = """
    The customer is booking an Instaclean visit on WhatsApp.
    Status: #{offer.status}
    Offered dates:
    #{Enum.map_join(slots, "\n", & &1.label)}
    They may also name any later date and a time between 06:00 and 20:00.
    Customer said: #{String.slice(to_string(body), 0, 400)}
    Return JSON only: {"action":"book"|"schedule"|"clarify","date":"YYYY-MM-DD"|null,"time":"HH:MM"|null}
    Use book only when they agree to start. Use schedule only when a day and time are clear.
    """

    case complete(prompt) do
      {:ok, %{"action" => "book"}} when offer.status == "offered" ->
        :book

      {:ok, %{"action" => "schedule", "date" => date, "time" => time}}
      when offer.status == "awaiting_time" ->
        with {:ok, parsed_date} <- iso_date(date),
             {:ok, parsed_time} <- iso_time(time),
             :ok <- future_slot(parsed_date, today),
             :ok <- daytime(parsed_time) do
          {:schedule, Date.to_iso8601(parsed_date), parsed_time}
        else
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp apply_choice(offer, :book, today) do
    if offer.status == "offered" do
      case mark_awaiting(offer.id) do
        {:ok, updated} ->
          {:ok, updated,
           %{
             event: "awaiting_time",
             service: updated.service_name,
             amount: money(updated.amount_minor, updated.currency),
             slots: visit_slots(today)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :offer_closed}
    end
  end

  defp apply_choice(offer, {:schedule, date, time}, _today) do
    if offer.status == "awaiting_time" do
      assign_nearest(offer, date, time)
    else
      {:error, :needs_book}
    end
  end

  defp apply_choice(offer, :unknown, today) do
    {:ok, offer,
     %{
       event: clarify_event(offer.status),
       service: offer.service_name,
       amount: money(offer.amount_minor, offer.currency),
       slots: visit_slots(today)
     }}
  end

  defp assign_nearest(offer, date, time) do
    cleaners = nearest_cleaners(offer, date, time)

    case first_booking(offer, cleaners, date, time) do
      {:ok, booking_id, cleaner_id, cleaner_name, booked_date, booked_time} ->
        case save_assignment(offer, booking_id, cleaner_id, cleaner_name, booked_date, booked_time) do
          {:ok, updated} ->
            {:ok, updated,
             %{
               event: "assigned",
               service: updated.service_name,
               amount: money(updated.amount_minor, updated.currency),
               cleaner: cleaner_name,
               when: "#{booked_date} at #{booked_time}",
               address: updated.address,
               slots: []
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp first_booking(_offer, [], _date, _time), do: {:error, :no_cleaner}

  defp first_booking(offer, [{cleaner_id, _cleaner_name} | rest], date, time) do
    params = %{
      "serviceId" => offer.service_id,
      "cleanerId" => cleaner_id,
      "scheduledDate" => date,
      "scheduledTime" => time,
      "durationHours" => offer.duration_hours,
      "address" => offer.address,
      "timezone" => @timezone,
      "idempotencyKey" => offer.id,
      "directAssignment" => true,
      "specialInstructions" => "WhatsApp booking at #{money(offer.amount_minor, offer.currency)}."
    }

    case DirectBookings.create_booking(offer.customer_id, params) do
      {:ok, result} ->
        case text_uuid(Map.get(result, :id) || Map.get(result, "id")) do
          nil ->
            {:error, :database_unavailable}

          booking_id ->
            with :ok <- set_customer_price(booking_id, offer.amount_minor),
                 {:ok, stored_cleaner, stored_date, stored_time} <- booking_facts(booking_id) do
              {:ok, booking_id, stored_cleaner, cleaner_name(stored_cleaner), stored_date, stored_time}
            else
              {:error, reason} -> {:error, reason}
              :error -> {:error, :database_unavailable}
            end
        end

      _ ->
        first_booking(offer, rest, date, time)
    end
  end

  defp nearest_cleaners(offer, date, time) do
    located =
      if is_number(offer.latitude) and is_number(offer.longitude) do
        nearby(offer, date, time)
      else
        []
      end

    located
    |> Kernel.++(eligible(offer.service_id))
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp nearby(offer, date, time) do
    hours = offer.duration_hours |> round() |> max(1) |> min(24)

    case Repo.query(
           """
           SELECT id
           FROM public.get_nearby_available_cleaners($1, $2, 10000, $3::date, $4::time, $5)
           LIMIT 5
           """,
           [
             offer.latitude * 1.0,
             offer.longitude * 1.0,
             Date.from_iso8601!(date),
             clock(time),
             hours
           ]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.flat_map(rows, fn [id] ->
          case text_uuid(id) do
            nil -> []
            cleaner_id -> [{cleaner_id, cleaner_name(cleaner_id)}]
          end
        end)

      _ ->
        []
    end
  end

  defp eligible(service_id) do
    case Repo.query(
           """
           SELECT cd.user_id::text
           FROM public.cleaner_data cd
           JOIN public.service_types st ON st.id = $1
           WHERE cd.verified = true
             AND cd.status = 'active'
             AND cd.hourly_rate IS NOT NULL
             AND cd.hourly_rate > 0
             AND st.specialty_slug = ANY(COALESCE(cd.specialties, ARRAY[]::text[]))
           ORDER BY COALESCE(cd.rating, 0) DESC, cd.user_id
           LIMIT 5
           """,
           [service_id]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.flat_map(rows, fn [id] ->
          case text_uuid(id) do
            nil -> []
            cleaner_id -> [{cleaner_id, cleaner_name(cleaner_id)}]
          end
        end)

      _ ->
        []
    end
  end

  defp cleaner_name(cleaner_id) do
    case Repo.query(
           "SELECT split_part(COALESCE(fullname, 'your cleaner'), ' ', 1) FROM public.profiles WHERE id = $1",
           [
             dump!(cleaner_id)
           ]
         ) do
      {:ok, %{rows: [[name]]}} when is_binary(name) and name != "" -> name
      _ -> "Your cleaner"
    end
  end

  defp booking_facts(booking_id) do
    case Repo.query(
           """
           SELECT cleaner_id::text, scheduled_date::text, to_char(scheduled_time, 'HH24:MI')
           FROM public.bookings
           WHERE id = $1
           """,
           [dump!(booking_id)]
         ) do
      {:ok, %{rows: [[cleaner_id, date, time]]}} when is_binary(cleaner_id) ->
        {:ok, cleaner_id, date, time}

      _ ->
        :error
    end
  end

  defp error_event(:no_cleaner, _status), do: "no_cleaner"
  defp error_event(_reason, status), do: clarify_event(status)

  defp set_customer_price(booking_id, amount_minor) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET final_amount_minor = $2, total_price = $2, updated_at = now()
           WHERE id = $1 AND payment_status = 'pending'
           """,
           [dump!(booking_id), amount_minor]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :price_not_applied}
      {:error, _} -> {:error, :database_unavailable}
    end
  end

  defp phrase(_offer, body, facts) do
    stock = stock_reply(facts)

    prompt = """
    Write one short WhatsApp reply as Instaclean.
    Use only these facts. Do not invent a cleaner, a price, or a time.
    Facts: #{Jason.encode!(facts)}
    Customer said: #{String.slice(to_string(body), 0, 240)}
    Return JSON {"reply":"..."}
    """

    case complete(prompt) do
      {:ok, %{"reply" => reply}} when is_binary(reply) ->
        trimmed = String.trim(reply)

        if phrase_ok?(trimmed, facts) do
          trimmed
        else
          stock
        end

      _ ->
        stock
    end
  end

  defp phrase_ok?(reply, facts) do
    amount = Map.get(facts, :amount)

    String.length(reply) in 1..500 and
      (amount == nil or String.contains?(reply, amount) or
         facts.event not in ["awaiting_time", "assigned"])
  end

  defp complete(prompt) do
    case Application.get_env(:mithril, :booking_offer_complete) do
      fun when is_function(fun, 1) ->
        fun.(prompt)

      _ ->
        openai_complete(prompt)
    end
  end

  defp openai_complete(prompt) do
    key = Application.get_env(:mithril, :openai_api_key)

    if is_binary(key) and key != "" do
      body = %{
        model: Application.get_env(:mithril, :booking_offer_model, "gpt-4.1-mini"),
        temperature: 0.4,
        response_format: %{type: "json_object"},
        messages: [%{role: "user", content: prompt}]
      }

      case Req.post(@openai_url,
             json: body,
             headers: [{"authorization", "Bearer #{key}"}],
             receive_timeout: 12_000
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
          decode_json(content)

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp decode_json(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp decode_json(_), do: :error

  defp schedule_from_text(text, today) do
    slots = visit_slots(today)

    cond do
      index = slot_index(text) ->
        slot = Enum.at(slots, index - 1)
        %{date: slot.date, time: parse_time(text) || slot.time}

      true ->
        parse_when(text, today)
    end
  end

  defp slot_index(text) do
    case Regex.run(~r/^\s*([123])\b/, String.trim(text)) do
      [_, digit] -> String.to_integer(digit)
      _ -> nil
    end
  end

  defp parse_when(text, today) do
    down = String.downcase(text)

    date =
      cond do
        String.contains?(down, "tomorrow") ->
          Date.add(today, 1)

        iso = Regex.run(~r/\b(\d{4}-\d{2}-\d{2})\b/, down) ->
          case Date.from_iso8601(Enum.at(iso, 1)) do
            {:ok, parsed} -> parsed
            _ -> nil
          end

        named = named_date(down, today) ->
          named

        weekday = next_weekday(down, today) ->
          weekday

        true ->
          nil
      end

    if match?(%Date{}, date) and Date.compare(date, today) == :gt do
      %{date: Date.to_iso8601(date), time: parse_time(down) || "09:00"}
    else
      nil
    end
  end

  defp named_date(text, today) do
    months = ~w(jan feb mar apr may jun jul aug sep oct nov dec)

    case Regex.run(~r/\b(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)/, text) do
      [_, day, mon] ->
        month = Enum.find_index(months, &(&1 == mon)) + 1

        case Date.new(today.year, month, String.to_integer(day)) do
          {:ok, date} ->
            if Date.compare(date, today) == :gt do
              date
            else
              shift_year(date)
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp shift_year(date) do
    case Date.new(date.year + 1, date.month, date.day) do
      {:ok, shifted} -> shifted
      _ -> nil
    end
  end

  defp next_weekday(text, today) do
    names = ~w(monday tuesday wednesday thursday friday saturday sunday)

    case Enum.find_index(names, &String.contains?(text, &1)) do
      nil ->
        nil

      index ->
        target = index + 1
        delta = rem(target - Date.day_of_week(today) + 7, 7)

        days =
          if delta == 0 do
            7
          else
            delta
          end

        Date.add(today, days)
    end
  end

  defp parse_time(text) do
    cond do
      clock = Regex.run(~r/\b([01]?\d|2[0-3]):([0-5]\d)\b/, text) ->
        hour = String.to_integer(Enum.at(clock, 1))
        minute = Enum.at(clock, 2)

        if hour <= 23 do
          pad_time(hour, minute)
        else
          nil
        end

      ampm = Regex.run(~r/\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b/, text) ->
        hour = String.to_integer(Enum.at(ampm, 1))
        minute = Enum.at(ampm, 2) || "00"
        suffix = Enum.at(ampm, 3)
        adjusted = to_24(hour, suffix)

        if adjusted do
          pad_time(adjusted, minute)
        else
          nil
        end

      true ->
        nil
    end
  end

  defp to_24(hour, _suffix) when hour < 1 or hour > 12, do: nil
  defp to_24(12, "am"), do: 0
  defp to_24(12, "pm"), do: 12
  defp to_24(hour, "am"), do: hour
  defp to_24(hour, "pm"), do: hour + 12

  defp pad_time(hour, minute) do
    "#{String.pad_leading(Integer.to_string(hour), 2, "0")}:#{String.pad_leading(minute, 2, "0")}"
  end

  defp book_button?(payload), do: String.starts_with?(payload, "book_visit")

  defp book_word?(text) do
    String.downcase(String.trim(text)) in ["book", "yes", "ok", "okay"]
  end

  defp future_slot(%Date{} = date, %Date{} = today) do
    if Date.compare(date, today) == :gt do
      :ok
    else
      :error
    end
  end

  defp daytime(time) do
    if time >= "06:00" and time <= "20:00" do
      :ok
    else
      :error
    end
  end

  defp today do
    case DateTime.now(@timezone) do
      {:ok, now} -> DateTime.to_date(now)
      _ -> Date.utc_today()
    end
  end

  defp weekday(date) do
    Enum.at(
      ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday),
      Date.day_of_week(date) - 1
    )
  end

  defp month(date) do
    Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), date.month - 1)
  end

  defp money(minor, currency) when is_integer(minor) do
    "#{currency} #{div(minor, 100)}.#{String.pad_leading(Integer.to_string(rem(minor, 100)), 2, "0")}"
  end

  defp validate_start(params) do
    with {:ok, customer_id} <- required_uuid(params["customerUserId"] || params[:customerUserId]),
         {:ok, service_id} <- positive_integer(params["serviceId"] || params[:serviceId]),
         {:ok, amount_minor} <- amount(params["amountMinor"] || params[:amountMinor]),
         {:ok, address} <- required_text(params["address"] || params[:address], 3, 500),
         {:ok, latitude} <- optional_coord(params["latitude"] || params[:latitude], -90, 90),
         {:ok, longitude} <- optional_coord(params["longitude"] || params[:longitude], -180, 180),
         {:ok, duration} <- duration(params["durationHours"] || params[:durationHours]) do
      {:ok,
       %{
         customer_id: customer_id,
         service_id: service_id,
         amount_minor: amount_minor,
         address: address,
         latitude: latitude,
         longitude: longitude,
         duration_hours: duration
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp load_customer(customer_id) do
    case Repo.query(
           """
           SELECT u.id::text, u.phone, split_part(COALESCE(p.fullname, 'there'), ' ', 1)
           FROM public.users u
           LEFT JOIN public.profiles p ON p.id = u.id
           WHERE u.id = $1
           """,
           [dump!(customer_id)]
         ) do
      {:ok, %{rows: [[id, phone, name]]}} ->
        case Phone.normalize(to_string(phone)) do
          {:ok, e164} -> {:ok, %{id: id, phone: e164, name: name}}
          :error -> {:error, :invalid_phone}
        end

      {:ok, _} ->
        {:error, :customer_not_found}

      {:error, _} ->
        {:error, :database_unavailable}
    end
  end

  defp load_service(service_id) do
    case Repo.query("SELECT name FROM public.service_types WHERE id = $1", [service_id]) do
      {:ok, %{rows: [[name]]}} when is_binary(name) -> {:ok, name}
      {:ok, _} -> {:error, :service_not_found}
      {:error, _} -> {:error, :database_unavailable}
    end
  end

  defp no_open_offer(phone) do
    case Repo.query(
           "SELECT 1 FROM public.whatsapp_booking_offers WHERE phone = $1 AND status IN ('offered', 'awaiting_time') LIMIT 1",
           [phone]
         ) do
      {:ok, %{rows: []}} -> :ok
      {:ok, _} -> {:error, :offer_open}
      {:error, _} -> {:error, :database_unavailable}
    end
  end

  defp insert_offer(admin_id, customer, service_name, input) do
    id = Ecto.UUID.generate()

    case Repo.query(
           """
           INSERT INTO public.whatsapp_booking_offers
             (id, customer_id, phone, service_id, service_name, amount_minor, address,
              latitude, longitude, duration_hours, created_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
           RETURNING id::text, status
           """,
           [
             dump!(id),
             dump!(customer.id),
             customer.phone,
             input.service_id,
             service_name,
             input.amount_minor,
             input.address,
             input.latitude,
             input.longitude,
             input.duration_hours,
             dump!(admin_id)
           ]
         ) do
      {:ok, %{rows: [[offer_id, status]]}} ->
        {:ok,
         %{
           id: offer_id,
           status: status,
           customer_id: customer.id,
           phone: customer.phone,
           name: customer.name,
           service_id: input.service_id,
           service_name: service_name,
           amount_minor: input.amount_minor,
           currency: "GHS",
           address: input.address,
           latitude: input.latitude,
           longitude: input.longitude,
           duration_hours: input.duration_hours,
           booking_id: nil,
           cleaner_name: nil,
           scheduled_date: nil,
           scheduled_time: nil
         }}

      {:error, _} ->
        {:error, :database_unavailable}
    end
  end

  defp send_offer(admin_id, offer, sid) do
    amount = money(offer.amount_minor, offer.currency)

    body =
      "Hi #{offer.name}, we can book #{offer.service_name} for #{amount}. Tap Book when you want it, and we will ask when it suits you."

    case DirectAdminWhatsApp.deliver_content_as_staff(
           dump!(admin_id),
           %{"phoneE164" => offer.phone, "body" => body},
           sid,
           %{"1" => offer.name, "2" => offer.service_name, "3" => amount}
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> rollback_offer(offer.id, reason)
    end
  end

  defp rollback_offer(offer_id, reason) do
    Repo.query(
      "DELETE FROM public.whatsapp_booking_offers WHERE id = $1 AND status = 'offered'",
      [
        dump!(offer_id)
      ]
    )

    {:error, reason}
  end

  defp content_sid do
    case Application.get_env(:mithril, :twilio_booking_offer_content_sid) do
      sid when is_binary(sid) and sid != "" ->
        {:ok, sid}

      _ ->
        ContentTemplate.ensure(
          @template_key,
          :twilio_booking_offer_content_sid,
          template_definition()
        )
    end
  end

  defp template_definition do
    %{
      "friendly_name" => "instaclean_whatsapp_booking_offer",
      "language" => "en",
      "types" => %{
        "twilio/quick-reply" => %{
          "body" =>
            "Hi {{1}}, we can book {{2}} for {{3}}. Tap Book when you want it, and we will ask when it suits you.",
          "actions" => [
            %{"title" => "Book", "id" => "book_visit"}
          ]
        }
      },
      "variables" => %{"1" => "Ama", "2" => "Regular Cleaning", "3" => "GHS 150.00"}
    }
  end

  defp mark_awaiting(offer_id) do
    case Repo.query(
           """
           UPDATE public.whatsapp_booking_offers
           SET status = 'awaiting_time', updated_at = now()
           WHERE id = $1 AND status = 'offered'
           RETURNING id::text
           """,
           [dump!(offer_id)]
         ) do
      {:ok, %{rows: [[_]]}} -> load_by_id(offer_id)
      {:ok, _} -> {:error, :offer_closed}
      {:error, _} -> {:error, :database_unavailable}
    end
  end

  defp save_assignment(offer, booking_id, cleaner_id, cleaner_name, date, time) do
    case Repo.query(
           """
           UPDATE public.whatsapp_booking_offers
           SET status = 'assigned', booking_id = $2, cleaner_id = $3, cleaner_name = $4,
               scheduled_date = $5::date, scheduled_time = $6::time, updated_at = now()
           WHERE id = $1 AND status = 'awaiting_time'
           """,
           [
             dump!(offer.id),
             dump!(booking_id),
             dump!(cleaner_id),
             cleaner_name,
             Date.from_iso8601!(date),
             Time.from_iso8601!(time <> ":00")
           ]
         ) do
      {:ok, %{num_rows: 1}} -> load_by_id(offer.id)
      {:ok, _} -> {:error, :offer_closed}
      {:error, _} -> {:error, :database_unavailable}
    end
  end

  defp load_latest(phone) do
    case Repo.query(
           """
           SELECT id::text FROM public.whatsapp_booking_offers
           WHERE phone = $1
           ORDER BY created_at DESC
           LIMIT 1
           """,
           [phone]
         ) do
      {:ok, %{rows: [[id]]}} -> load_by_id(id)
      {:ok, _} -> {:error, :not_found}
      {:error, _} -> {:error, :database_unavailable}
    end
  end

  defp load_by_id(offer_id) do
    with {:ok, dumped} <- dump_uuid(offer_id) do
      case Repo.query(
             """
             SELECT id::text, customer_id::text, phone, service_id, service_name, amount_minor,
                    currency, address, latitude, longitude, duration_hours, status,
                    booking_id::text, cleaner_name, scheduled_date::text, to_char(scheduled_time, 'HH24:MI')
             FROM public.whatsapp_booking_offers
             WHERE id = $1
             """,
             [dumped]
           ) do
        {:ok, %{rows: [row]}} -> {:ok, offer_row(row)}
        {:ok, _} -> {:error, :not_found}
        {:error, _} -> {:error, :database_unavailable}
      end
    else
      :error -> {:error, :invalid_request}
    end
  end

  defp offer_row([
         id,
         customer_id,
         phone,
         service_id,
         service_name,
         amount_minor,
         currency,
         address,
         latitude,
         longitude,
         duration_hours,
         status,
         booking_id,
         cleaner_name,
         scheduled_date,
         scheduled_time
       ]) do
    %{
      id: id,
      customer_id: customer_id,
      phone: phone,
      name: "there",
      service_id: service_id,
      service_name: service_name,
      amount_minor: amount_minor,
      currency: currency,
      address: address,
      latitude: latitude,
      longitude: longitude,
      duration_hours: decimal_hours(duration_hours),
      status: status,
      booking_id: booking_id,
      cleaner_name: cleaner_name,
      scheduled_date: scheduled_date,
      scheduled_time: scheduled_time
    }
  end

  defp public_offer(offer) do
    %{
      offerId: offer.id,
      status: offer.status,
      customerUserId: offer.customer_id,
      phoneE164: offer.phone,
      serviceId: offer.service_id,
      serviceName: offer.service_name,
      amountMinor: offer.amount_minor,
      currency: offer.currency,
      address: offer.address,
      bookingId: offer.booking_id,
      cleanerName: offer.cleaner_name,
      scheduledDate: offer.scheduled_date,
      scheduledTime: offer.scheduled_time,
      slots: offer_slots(offer)
    }
  end

  defp stored_reply(sid) when is_binary(sid) and sid != "" do
    case Repo.query(
           "SELECT reply FROM public.whatsapp_booking_offer_messages WHERE message_sid = $1",
           [sid]
         ) do
      {:ok, %{rows: [[reply]]}} -> reply
      _ -> nil
    end
  end

  defp stored_reply(_), do: nil

  defp remember_reply(sid, phone, reply) when is_binary(sid) and sid != "" do
    Repo.query(
      """
      INSERT INTO public.whatsapp_booking_offer_messages (message_sid, phone, reply)
      VALUES ($1, $2, $3)
      ON CONFLICT (message_sid) DO NOTHING
      """,
      [sid, phone, reply]
    )

    reply
  end

  defp remember_reply(_sid, _phone, reply), do: reply

  defp remember_inbox(phone, body) do
    Repo.query(
      """
      INSERT INTO public.whatsapp_inbox_messages (direction, phone_e164, body, user_id)
      SELECT 'outbound', $1, $2, customer_id
      FROM public.whatsapp_booking_offers
      WHERE phone = $1
      ORDER BY created_at DESC
      LIMIT 1
      """,
      [phone, body]
    )

    :ok
  end

  defp open_offer?(phone) do
    case Repo.query(
           """
           SELECT 1 FROM public.whatsapp_booking_offers
           WHERE phone = $1 AND status IN ('offered', 'awaiting_time')
           LIMIT 1
           """,
           [phone]
         ) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  defp verify(params, signature) do
    token = Application.get_env(:mithril, :twilio_auth_token)
    urls = webhook_urls()

    cond do
      Application.get_env(:mithril, :booking_offer_skip_signature) == true ->
        :ok

      not is_binary(token) or token == "" or urls == [] ->
        :not_configured

      Enum.any?(urls, &TwilioSignature.valid?(params, signature, token, &1)) ->
        :ok

      true ->
        :unauthorized
    end
  end

  defp webhook_urls do
    [:twilio_booking_offer_webhook_url, :twilio_booking_offer_webhook_url_alias]
    |> Enum.map(&Application.get_env(:mithril, &1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
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
    Parse.string_param(params, "ButtonPayload") || Parse.string_param(params, "ButtonResponse")
  end

  defp require_admin(admin_id) do
    if Auth.staff_uuid?(admin_id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp clock(time) do
    value =
      if String.length(time) == 5 do
        time <> ":00"
      else
        time
      end

    Time.from_iso8601!(value)
  end

  defp clarify_event("awaiting_time"), do: "clarify"
  defp clarify_event(_status), do: "prompt_book"

  defp offer_slots(%{status: "awaiting_time"}) do
    visit_slots(today())
  end

  defp offer_slots(_offer), do: []

  defp text_uuid(value) when is_binary(value) and byte_size(value) == 16 do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp text_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp text_uuid(_), do: nil

  defp decimal_hours(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_hours(value) when is_integer(value), do: value * 1.0
  defp decimal_hours(value) when is_float(value), do: value

  defp decimal_hours(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      _ -> 2.0
    end
  end

  defp decimal_hours(_), do: 2.0

  defp amount(value) when is_integer(value) and value >= 100, do: {:ok, value}

  defp amount(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 100 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp amount(_), do: :error

  defp duration(nil), do: {:ok, 2.0}

  defp duration(value) when is_integer(value) and value >= 1 and value <= 24,
    do: {:ok, value * 1.0}

  defp duration(value) when is_float(value) and value >= 1 and value <= 24, do: {:ok, value}

  defp duration(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 1 and parsed <= 24 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp duration(_), do: :error

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp positive_integer(_), do: :error

  defp optional_coord(nil, _min, _max), do: {:ok, nil}
  defp optional_coord("", _min, _max), do: {:ok, nil}

  defp optional_coord(value, min, max) when is_number(value) and value >= min and value <= max,
    do: {:ok, value * 1.0}

  defp optional_coord(value, min, max) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
      _ -> :error
    end
  end

  defp optional_coord(_, _, _), do: :error

  defp required_text(value, min, max) when is_binary(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) >= min and String.length(trimmed) <= max do
      {:ok, trimmed}
    else
      :error
    end
  end

  defp required_text(_, _, _), do: :error

  defp required_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp required_uuid(_), do: :error

  defp iso_date(%Date{} = date), do: {:ok, date}

  defp iso_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp iso_date(_), do: :error

  defp iso_time(value) when is_binary(value) do
    case parse_time(value) do
      nil -> :error
      time -> {:ok, time}
    end
  end

  defp iso_time(_), do: :error

  defp dump_uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> {:ok, dumped}
      :error -> :error
    end
  end

  defp dump_uuid(_), do: :error

  defp dump!(value) do
    {:ok, dumped} = Ecto.UUID.dump(value)
    dumped
  end
end
