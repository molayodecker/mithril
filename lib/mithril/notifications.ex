defmodule Mithril.Notifications do
  @moduledoc """
  Optional concierge/dispatch notifications after an admin action, plus
  Oban visit reminders for Direct concierge bookings.

  Booking create and worker assignment stay saved if delivery fails.
  When `SEND_NOTIFICATION_URL` is set, Instaclean's `send-notification`
  edge function delivers email, SMS, and WhatsApp templates. Otherwise
  Twilio SMS is used with the same credentials as phone OTP.
  """

  require Logger

  alias Mithril.Auth.SMS
  alias Mithril.Notifications.SendNotification
  alias Mithril.Repo

  def enabled?(params) when is_map(params) do
    case Map.get(params, "sendNotifications", true) do
      value when value in [false, "false", "off", 0, "0"] -> false
      _ -> true
    end
  end

  def notify(%{send_notifications: false}), do: false

  def notify(ctx) when is_map(ctx) do
    try do
      deliver(ctx)
    rescue
      error ->
        Logger.error("Direct notification crashed: #{inspect(error)}")
        false
    end
  end

  def load_party(user_id) when is_binary(user_id) do
    with {:ok, uid} <- Ecto.UUID.dump(user_id),
         {:ok, %{rows: [[email, phone, name]]}} <-
           Repo.query(
             """
             SELECT u.email, u.phone,
                    COALESCE(
                      NULLIF(btrim(p.fullname), ''),
                      NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
                      'there'
                    )
             FROM public.users u
             LEFT JOIN public.profiles p ON p.id = u.id
             WHERE u.id = $1
             LIMIT 1
             """,
             [uid]
           ) do
      %{
        user_id: user_id,
        email: present(email),
        phone: present(phone),
        name: present(name) || "there"
      }
    else
      _ -> nil
    end
  end

  def load_party(_), do: nil

  defp deliver(ctx) do
    cond do
      SendNotification.configured?() -> SendNotification.deliver(ctx)
      true -> deliver_sms(ctx)
    end
  end

  defp deliver_sms(ctx) do
    case ctx[:recipient] do
      :customer ->
        send_sms(ctx[:customer], customer_sms(ctx))

      :worker ->
        send_sms(ctx[:worker], worker_sms(ctx))

      _ ->
        customer_sent = send_sms(ctx[:customer], customer_sms(ctx))
        worker_sent = send_sms(ctx[:worker], worker_sms(ctx))
        customer_sent or worker_sent
    end
  end

  defp send_sms(party, body) when is_binary(body) do
    phone = party && present(party[:phone] || party["phone"])

    case phone && SMS.send_message(phone, body) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("Direct notification SMS failed: #{inspect(reason)}")
        false

      _ ->
        false
    end
  end

  defp customer_sms(%{kind: :booking_reminder} = ctx) do
    summary = visit_summary(ctx)
    address = ctx[:address] || ""
    tail = if address != "", do: " · #{address}", else: ""

    "Instaclean reminder: #{summary}#{tail}. Secure valuables before the visit — Instaclean is not liable for unsecured items."
  end

  defp customer_sms(%{kind: :dispatch_assignment} = ctx) do
    worker = party_name(ctx[:worker], "Your Instaclean professional")
    role = humanize(ctx[:role] || "help")
    "Instaclean: #{worker} is assigned for your #{role} request."
  end

  defp customer_sms(%{kind: :admin_receipt} = ctx) do
    summary = visit_summary(ctx)
    url = payment_url(ctx[:booking_id])
    amount = format_amount(ctx[:amount_minor], ctx[:currency])
    "Instaclean receipt: #{summary} · #{amount}. Details: #{url}"
  end

  defp customer_sms(ctx) do
    worker = party_name(ctx[:worker], "Your cleaner")
    summary = visit_summary(ctx)
    url = payment_url(ctx[:booking_id])
    "Instaclean: #{worker} is confirmed for #{summary}. Pay: #{url}"
  end

  defp worker_sms(%{kind: :booking_reminder} = ctx) do
    customer = party_name(ctx[:customer], "a customer")
    summary = visit_summary(ctx)
    address = ctx[:address] || ""
    tail = if address != "", do: " · #{address}", else: ""
    "Instaclean job reminder: #{summary}#{tail} · #{customer}"
  end

  defp worker_sms(%{kind: :dispatch_assignment} = ctx) do
    address = ctx[:address] || "the household"
    when_at = format_datetime(ctx[:requested_start_at])
    tail = if when_at, do: " · #{when_at}", else: ""
    "Instaclean: New dispatch job · #{address}#{tail}"
  end

  defp worker_sms(%{kind: :admin_notify_cleaner} = ctx) do
    customer = party_name(ctx[:customer], "a customer")
    summary = visit_summary(ctx)
    address = ctx[:address] || ""
    tail = if address != "", do: " · #{address}", else: ""
    "Instaclean: Reminder for your booking with #{customer} · #{summary}#{tail}"
  end

  defp worker_sms(ctx) do
    customer = party_name(ctx[:customer], "a customer")
    summary = visit_summary(ctx)
    address = ctx[:address] || ""
    tail = if address != "", do: " · #{address}", else: ""
    "Instaclean: New booking for #{customer} · #{summary}#{tail}"
  end

  def visit_summary(ctx) do
    dates = List.wrap(ctx[:dates]) |> Enum.filter(&is_binary/1)
    time = format_time(ctx[:scheduled_time])

    date_part =
      case dates do
        [date] -> date
        [_ | _] -> "#{length(dates)} visits from #{hd(dates)}"
        [] -> "the scheduled time"
      end

    if time, do: "#{date_part} at #{time}", else: date_part
  end

  def payment_url(booking_id) when is_binary(booking_id) do
    base =
      Application.get_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")
      |> to_string()
      |> String.trim_trailing("/")

    "#{base}/bookings/#{booking_id}"
  end

  def payment_url(_), do: "https://direct.tryinstaclean.com/bookings"

  defp party_name(nil, fallback), do: fallback

  defp party_name(party, fallback) do
    present(party[:name] || party["name"]) || fallback
  end

  defp format_time(nil), do: nil

  defp format_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  defp format_time(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 5)
    |> case do
      "" -> nil
      time -> time
    end
  end

  defp format_time(_), do: nil

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = datetime) do
    shifted =
      case DateTime.shift_zone(datetime, "Africa/Accra") do
        {:ok, value} -> value
        _ -> datetime
      end

    Calendar.strftime(shifted, "%Y-%m-%d at %H:%M")
  end

  defp format_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> format_datetime(datetime)
      _ -> String.slice(value, 0, 16)
    end
  end

  defp format_datetime(_), do: nil

  defp humanize(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp humanize(_), do: "help"

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(_), do: nil

  defp format_amount(amount, currency) when is_integer(amount) do
    major = amount / 100
    code = present(currency) || "GHS"
    "#{code} #{:erlang.float_to_binary(major / 1, decimals: 2)}"
  end

  defp format_amount(_, currency), do: present(currency) || "GHS"
end
