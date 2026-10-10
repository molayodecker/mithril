defmodule Mithril.Notifications.Outbound do
  @moduledoc false

  alias Mithril.Auth.Phone
  alias Mithril.Auth.SMS

  def deliver(body) when is_map(body) do
    channel = present(body["channel"]) || ""
    email = present(body["email"])
    phone = present(body["phone"])
    template = present(body["template"]) || "booking_reminder"
    variables = if is_map(body["variables"]), do: body["variables"], else: %{}

    send_email = channel in ["email", "both", "all"] and email != nil
    send_sms = channel in ["sms", "both", "all"] and phone != nil
    send_whatsapp = channel == "whatsapp" and phone != nil

    email_sent = if send_email, do: email_ok?(email, template, variables), else: false
    sms_sent = if send_sms, do: sms_ok?(phone, template, variables), else: false

    whatsapp_sent =
      cond do
        send_whatsapp ->
          whatsapp_ok?(phone, template, variables, body)

        sms_fallback?(body) and send_sms and not sms_sent ->
          whatsapp_ok?(phone, template, variables, body)

        true ->
          false
      end

    %{"emailSent" => email_sent, "smsSent" => sms_sent, "whatsappSent" => whatsapp_sent}
  end

  defp sms_fallback?(body) do
    body["smsFallbackToWhatsapp"] in [true, "true"]
  end

  defp email_ok?(email, template, variables) do
    api_key = env(:resend_api_key)

    if api_key == nil do
      false
    else
      body = %{
        from:
          Application.get_env(
            :mithril,
            :resend_from,
            "Instaclean <noreply@update.tryinstaclean.com>"
          ),
        to: [email],
        subject: subject(template),
        html: "<p>#{html_escape(message_body(template, variables))}</p>"
      }

      case Req.post("https://api.resend.com/emails", json: body, auth: {:bearer, api_key}) do
        {:ok, %{status: status}} when status in 200..299 -> true
        _ -> false
      end
    end
  end

  defp sms_ok?(phone, template, variables) do
    SMS.send_message(phone, message_body(template, variables)) == :ok
  end

  defp whatsapp_ok?(phone, template, variables, body) do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)

    content_sid =
      present(body["whatsappContentSid"]) ||
        template_content_sid(template)

    from = whatsapp_address(env(:twilio_whatsapp_from))

    if sid == nil or token == nil or content_sid == nil or from == nil or
         whatsapp_address(phone) == nil do
      false
    else
      url = "https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json"
      to = whatsapp_address(phone)

      fields = [
        To: to,
        From: from,
        ContentSid: content_sid,
        ContentVariables: Jason.encode!(content_variables(template, variables))
      ]

      case Req.post(url, form: fields, auth: {:basic, "#{sid}:#{token}"}) do
        {:ok, %{status: status}} when status in 200..299 -> true
        _ -> false
      end
    end
  end

  @doc false
  def whatsapp_address(nil), do: nil

  def whatsapp_address(value) when is_binary(value) do
    number = String.replace(value, ~r/^whatsapp:/i, "")

    case Phone.normalize(number) do
      {:ok, normalized} -> "whatsapp:#{normalized}"
      :error -> nil
    end
  end

  defp template_content_sid("booking_reminder"), do: env(:twilio_template_booking_reminder)
  defp template_content_sid("review_request"), do: env(:twilio_template_review_request)
  defp template_content_sid("cleaner_en_route"), do: env(:twilio_template_cleaner_en_route)
  defp template_content_sid("cleaner_arrived"), do: env(:twilio_template_cleaner_arrived)
  defp template_content_sid("cleaner_assigned"), do: env(:twilio_template_cleaner_assigned)
  defp template_content_sid("new_booking"), do: env(:twilio_template_new_booking)
  defp template_content_sid("payment_received"), do: env(:twilio_template_payment_received)
  defp template_content_sid(_), do: nil

  defp content_variables("review_request", variables) do
    %{
      "1" => present(variables["cleanerName"]) || "your cleaner",
      "2" => present(variables["reviewUrl"]) || ""
    }
  end

  defp content_variables(template, variables)
       when template in ["cleaner_en_route", "cleaner_arrived"] do
    %{
      "1" => present(variables["cleanerName"]) || "Your cleaner",
      "2" => present(variables["bookingId"]) || "",
      "3" => present(variables["address"]) || ""
    }
  end

  defp content_variables(_template, variables) do
    %{
      "1" => present(variables["address"]) || "—",
      "2" => present(variables["service"]) || "Instaclean booking",
      "3" => present(variables["scheduled_date"]) || present(variables["date"]) || "—",
      "4" => present(variables["scheduled_time"]) || "—"
    }
  end

  defp message_body("booking_reminder", variables) do
    date = present(variables["date"]) || "the scheduled time"
    address = present(variables["address"])
    tail = if address, do: " · #{address}", else: ""

    if variables["recipientType"] == "cleaner" do
      "Instaclean job reminder: #{date}#{tail}"
    else
      "Instaclean reminder: #{date}#{tail}"
    end
  end

  defp message_body("payment_received", variables) do
    amount =
      present(variables["amount"]) || present(variables["amountFormatted"]) || "your payment"

    booking = present(variables["bookingId"])
    suffix = if booking, do: " for booking #{booking}", else: ""
    "Instaclean payment received: #{amount}#{suffix}."
  end

  defp message_body("cleaner_assigned", variables) do
    cleaner = present(variables["cleanerName"]) || "Your Instaclean professional"
    date = present(variables["date"])
    suffix = if date, do: " for #{date}", else: ""
    "Instaclean: #{cleaner} has been assigned#{suffix}."
  end

  defp message_body("new_booking", variables) do
    customer = present(variables["customerName"]) || "a customer"
    date = present(variables["date"]) || "the scheduled time"
    address = present(variables["address"])
    tail = if address, do: " · #{address}", else: ""
    "Instaclean: New booking for #{customer} · #{date}#{tail}"
  end

  defp message_body("cleaner_en_route", variables) do
    cleaner = present(variables["cleanerName"]) || "Your Instaclean professional"
    booking = present(variables["bookingId"])
    reference = if booking, do: " (booking #{booking})", else: ""
    "#{cleaner} is on the way#{reference}. Track your booking in the Instaclean app."
  end

  defp message_body("cleaner_arrived", variables) do
    cleaner = present(variables["cleanerName"]) || "Your Instaclean professional"
    address = present(variables["address"])
    destination = if address, do: " at #{address}", else: ""
    "#{cleaner} has arrived#{destination}. Check your Instaclean booking."
  end

  defp message_body("cleaner_milestone_support", variables) do
    cleaner = present(variables["cleanerName"]) || "A cleaner"
    customer = present(variables["customerName"]) || "a customer"

    label =
      present(variables["milestoneLabel"]) || present(variables["milestone"]) || "updated status"

    booking = present(variables["bookingId"]) || "unknown"
    email = present(variables["customerEmail"]) || "unavailable"
    phone = present(variables["customerPhone"]) || "unavailable"

    "#{cleaner} marked #{label} for booking #{booking} (customer: #{customer}; email: #{email}; phone: #{phone})."
  end

  defp message_body("review_request", variables) do
    cleaner = present(variables["cleanerName"]) || "your cleaner"
    review_url = present(variables["reviewUrl"])
    tail = if review_url, do: " #{review_url}", else: ""
    "How was your clean? Rate #{cleaner}.#{tail}"
  end

  defp message_body(_template, variables) do
    present(variables["message"]) || "Instaclean notification"
  end

  defp subject("booking_reminder"), do: "Reminder – upcoming Instaclean booking"
  defp subject("payment_received"), do: "Instaclean payment receipt"
  defp subject("cleaner_assigned"), do: "Your Instaclean professional is assigned"
  defp subject("new_booking"), do: "New Instaclean booking"
  defp subject("cleaner_en_route"), do: "Your Instaclean professional is on the way"
  defp subject("cleaner_arrived"), do: "Your Instaclean professional has arrived"
  defp subject("cleaner_milestone_support"), do: "Instaclean booking status update"
  defp subject("review_request"), do: "How was your clean?"
  defp subject(_), do: "Instaclean"

  defp env(key) do
    case Application.get_env(:mithril, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(_), do: nil

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
