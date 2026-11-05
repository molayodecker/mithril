defmodule Mithril.GoogleReview do
  @moduledoc """
  Staff ask a contract client or booking customer to review Instaclean on Google.

  WhatsApp uses an approved content template when one exists and otherwise sends
  the same request as a session message. Email is a designed message. Facebook
  has no customer account on file, so the response is a Messenger compose link
  the staff member opens.
  """

  alias Mithril.Notifications.Resend
  alias Mithril.WhatsApp.GoogleReviewTemplate

  @url "https://g.page/r/CZpfgtrjgJuTEBM/review"
  @channels ~w(whatsapp email facebook)

  def url, do: @url

  def send(admin_uid, channel, contact)
      when is_binary(admin_uid) and is_binary(channel) and is_map(contact) do
    if channel in @channels do
      deliver(admin_uid, channel, contact)
    else
      {:error, :invalid_request}
    end
  end

  def send(_admin_uid, _channel, _contact), do: {:error, :invalid_request}

  def session_message(name) do
    "Hello #{greeting(name)}, thank you for choosing Instaclean. If the work was good, please review us on Google: #{@url}"
  end

  def email(name) do
    who = greeting(name)

    %{
      subject: "Would you review Instaclean on Google?",
      text: text(who),
      html: html(who)
    }
  end

  def facebook_url do
    link = URI.encode_www_form(@url)
    app_id = Application.get_env(:mithril, :facebook_app_id, "") |> to_string() |> String.trim()

    if app_id == "" do
      "https://www.facebook.com/sharer/sharer.php?u=#{link}"
    else
      redirect = URI.encode_www_form("https://direct.tryinstaclean.com/")

      "https://www.facebook.com/dialog/send?app_id=#{URI.encode_www_form(app_id)}&link=#{link}&redirect_uri=#{redirect}"
    end
  end

  def greeting(name) do
    case blank_to_nil(name) do
      nil -> "there"
      value -> value
    end
  end

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  def blank_to_nil(_), do: nil

  defp deliver(_admin_uid, "facebook", _contact) do
    {:ok, payload("facebook", false, facebook_url())}
  end

  defp deliver(admin_uid, "whatsapp", contact) do
    case blank_to_nil(contact.phone) do
      nil ->
        {:error, :missing_phone}

      phone ->
        case GoogleReviewTemplate.deliver(admin_uid, phone, greeting(contact.name)) do
          :ok -> {:ok, payload("whatsapp", true, nil)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp deliver(_admin_uid, "email", contact) do
    case blank_to_nil(contact.email) do
      nil ->
        {:error, :missing_email}

      email ->
        message = email(contact.name)

        case Resend.deliver(%{
               to: email,
               subject: message.subject,
               html: message.html,
               text: message.text
             }) do
          :ok -> {:ok, payload("email", true, nil)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp payload(channel, sent, share_url) do
    %{"ok" => true, "channel" => channel, "sent" => sent, "shareUrl" => share_url}
  end

  defp text(greeting) do
    """
    Hello #{greeting},

    Thank you for choosing Instaclean. If the work was good, a short Google review helps other customers find a team they can trust.

    Review us on Google: #{@url}
    """
    |> String.trim()
  end

  defp html(greeting) do
    safe_name = html_escape(greeting)

    """
    <!doctype html>
    <html>
      <body style="margin:0;background:#f4f1ea;color:#14213d;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f1ea;">
          <tr>
            <td align="center" style="padding:32px 16px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:16px;overflow:hidden;">
                <tr>
                  <td style="background:#0d1859;padding:28px 32px;font-family:Georgia,serif;">
                    <div style="color:#f6c400;font-size:12px;letter-spacing:0.16em;">INSTACLEAN</div>
                    <div style="color:#ffffff;font-size:28px;line-height:1.2;margin-top:8px;">How did we do?</div>
                  </td>
                </tr>
                <tr>
                  <td style="padding:32px;font-family:Georgia,serif;font-size:16px;line-height:1.5;">
                    <p style="margin:0 0 16px;">Hello #{safe_name},</p>
                    <p style="margin:0 0 16px;">Thank you for choosing Instaclean. If the work was good, a short Google review helps other customers find a team they can trust.</p>
                    <p style="margin:28px 0;">
                      <a href="#{@url}" style="background:#f6c400;color:#0d1859;text-decoration:none;padding:14px 22px;border-radius:999px;font-weight:700;display:inline-block;">Review us on Google</a>
                    </p>
                    <p style="margin:0;color:#5c6478;font-size:14px;">Or copy this link:<br><a href="#{@url}" style="color:#0d1859;">#{@url}</a></p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp html_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
