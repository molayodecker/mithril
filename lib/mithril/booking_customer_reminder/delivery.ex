defmodule Mithril.BookingCustomerReminder.Delivery do
  @moduledoc false

  alias Mithril.BookingCustomerReminder.Schedule
  alias Mithril.Constants.BookingValuablesNotice
  alias Mithril.Notifications.ExpoPush
  alias Mithril.Notifications.SendNotification
  alias Mithril.Repo

  @spec notify(map(), map(), :customer | :cleaner, Schedule.reminder_stage(), keyword()) :: map()
  def notify(row, recipient, recipient_type, stage, opts \\ []) do
    booking_id = to_string(row["id"])
    recipient_id = recipient[:user_id]

    date_combined =
      Schedule.format_scheduled_combined(row["scheduled_date"], row["scheduled_time"])

    stage_label = Schedule.stage_label(stage)

    {push_title, base_body} =
      if stage == :customer_morning do
        {"Your cleaning is today",
         "Your #{service_title(row)} is scheduled for #{date_combined}."}
      else
        {"Upcoming cleaning reminder", reminder_body(row, recipient_type, date_combined)}
      end

    push_body =
      if recipient_type == :customer do
        "#{base_body} #{BookingValuablesNotice.notice()}"
      else
        base_body
      end

    dedupe_key = "#{recipient_type}_booking_reminder:#{stage_label}:#{booking_id}"

    inbox_inserted =
      insert_inbox(
        recipient_id,
        push_title,
        push_body,
        dedupe_key,
        booking_id,
        recipient_type,
        stage_label
      )

    tokens = load_push_tokens(recipient_id, recipient_type)

    push_sent =
      ExpoPush.send_tokens(tokens, %{
        title: push_title,
        body: push_body,
        data: %{
          "type" => "booking_reminder",
          "bookingId" => booking_id,
          "recipientType" => to_string(recipient_type),
          "reminderStage" => stage_label,
          "screen" => screen_for(recipient_type, booking_id)
        }
      })

    channel_result =
      notify_channels(row, recipient, recipient_type, stage, date_combined, booking_id, opts)

    Map.merge(channel_result, %{inbox_inserted: inbox_inserted, push_sent: push_sent})
  end

  defp reminder_body(row, :cleaner, date_combined) do
    "You have a job (#{service_title(row)}) scheduled for #{date_combined}."
  end

  defp reminder_body(row, :customer, date_combined) do
    "Your #{service_title(row)} is scheduled for #{date_combined}."
  end

  defp service_title(row) do
    case row["title"] |> to_string() |> String.trim() do
      "" -> "cleaning"
      title -> title
    end
  end

  defp screen_for(:cleaner, _booking_id), do: "/cleaner-dashboard/schedule"
  defp screen_for(:customer, booking_id), do: "/booking/status/#{booking_id}"

  defp insert_inbox(user_id, title, message, dedupe_key, booking_id, recipient_type, stage_label) do
    case Repo.query(
           """
           INSERT INTO public.notifications (user_id, type, title, message, read, dedupe_key, data)
           VALUES ($1::uuid, 'booking_reminder', $2, $3, false, $4, $5::jsonb)
           RETURNING id
           """,
           [
             user_id,
             title,
             message,
             dedupe_key,
             Jason.encode!(%{
               "booking_id" => booking_id,
               "type" => "booking_reminder",
               "recipient_type" => to_string(recipient_type),
               "reminder_stage" => stage_label,
               "screen" => screen_for(recipient_type, booking_id)
             })
           ]
         ) do
      {:ok, %{num_rows: 1}} ->
        true

      {:error, %{postgres: %{code: "23505"}}} ->
        true

      _ ->
        false
    end
  end

  defp load_push_tokens(user_id, :cleaner) do
    case Repo.query(
           """
           SELECT token FROM public.device_tokens WHERE user_id = $1::uuid
           UNION ALL
           SELECT expo_push_token AS token FROM public.cleaner_devices WHERE cleaner_id = $1::uuid
           """,
           [user_id]
         ) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [token] -> token end)
        |> Enum.filter(&ExpoPush.valid_token?/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp load_push_tokens(user_id, :customer) do
    case Repo.query("SELECT token FROM public.device_tokens WHERE user_id = $1::uuid", [user_id]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [token] -> token end)
        |> Enum.filter(&ExpoPush.valid_token?/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp notify_channels(row, recipient, recipient_type, stage, date_combined, booking_id, opts) do
    email = present(recipient[:email])
    phone = resolve_phone(row, recipient, recipient_type)

    channel =
      cond do
        is_nil(email) and is_nil(phone) -> nil
        email && phone -> "both"
        email -> "email"
        true -> "sms"
      end

    if channel == nil or not SendNotification.configured?() do
      %{email_sent: false, sms_sent: false, whatsapp_sent: false}
    else
      message_type =
        if recipient_type == :cleaner, do: "cleaner_booking_reminder", else: "booking_reminder"

      variables = %{
        "name" => recipient[:name] || "there",
        "bookingId" => booking_id,
        "date" => date_combined,
        "address" => to_string(row["address"] || ""),
        "scheduled_date" => to_string(row["scheduled_date"] || ""),
        "scheduled_time" => to_string(row["scheduled_time"] || ""),
        "title" => service_title(row),
        "service" => service_title(row),
        "customerName" => Keyword.get(opts, :customer_name, ""),
        "recipientType" => to_string(recipient_type),
        "reminderStage" => Schedule.stage_label(stage),
        "includeValuablesNotice" => if(recipient_type == :customer, do: "true", else: "false")
      }

      body = %{
        "template" => "booking_reminder",
        "channel" => channel,
        "userId" => recipient[:user_id],
        "bookingId" => booking_id,
        "messageType" => message_type,
        "smsFallbackToWhatsapp" => true,
        "email" => email,
        "phone" => phone,
        "variables" => variables
      }

      case SendNotification.invoke_mobile(body) do
        {:ok, response} ->
          %{
            email_sent: truthy?(response["emailSent"]),
            sms_sent: truthy?(response["smsSent"]),
            whatsapp_sent: truthy?(response["whatsappSent"])
          }

        _ ->
          %{email_sent: false, sms_sent: false, whatsapp_sent: false}
      end
    end
  end

  defp resolve_phone(row, recipient, :customer) do
    contact = row["customer_contact_phone"] |> to_string() |> String.trim()
    user_phone = present(recipient[:phone])
    if contact != "", do: contact, else: user_phone
  end

  defp resolve_phone(_row, recipient, :cleaner), do: present(recipient[:phone])

  defp present(nil), do: nil

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
