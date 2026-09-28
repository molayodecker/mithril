defmodule Mithril.Notifications.Outbound do
  @moduledoc false

  alias Mithril.Auth.SMS

  def deliver(body) when is_map(body) do
    channel = body["channel"] |> to_string() |> String.trim()
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
          whatsapp_ok?(phone, variables)

        sms_fallback?(body) and send_sms and not sms_sent ->
          whatsapp_ok?(phone, variables)

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

  defp whatsapp_ok?(phone, variables) do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)
    content_sid = env(:twilio_template_booking_reminder)
    from = env(:twilio_whatsapp_from)

    if sid == nil or token == nil or content_sid == nil or from == nil do
      false
    else
      url = "https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json"
      to = if String.starts_with?(phone, "whatsapp:"), do: phone, else: "whatsapp:#{phone}"

      fields = [
        To: to,
        From: from,
        ContentSid: content_sid,
        ContentVariables: Jason.encode!(content_variables(variables))
      ]

      case Req.post(url, form: fields, auth: {:basic, "#{sid}:#{token}"}) do
        {:ok, %{status: status}} when status in 200..299 -> true
        _ -> false
      end
    end
  end

  defp content_variables(variables) do
    %{
      "1" => present(variables["address"]) || "—",
      "2" => present(variables["service"]) || "Instaclean booking",
      "3" => present(variables["scheduled_date"]) || present(variables["date"]) || "—",
      "4" => present(variables["scheduled_time"]) || "—"
    }
  end

  defp message_body(_template, variables) do
    date = present(variables["date"]) || "the scheduled time"
    address = present(variables["address"])
    tail = if address, do: " · #{address}", else: ""

    if variables["recipientType"] == "cleaner" do
      "Instaclean job reminder: #{date}#{tail}"
    else
      "Instaclean reminder: #{date}#{tail}"
    end
  end

  defp subject("booking_reminder"), do: "Reminder – upcoming Instaclean booking"
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
