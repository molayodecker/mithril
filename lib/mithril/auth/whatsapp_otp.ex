defmodule Mithril.Auth.WhatsAppOtp do
  @moduledoc """
  Sends a phone OTP with the approved WhatsApp authentication template
  `instaclean_phone_otp_v3`.

  Variable `1` is the code. WhatsApp adds the security recommendation,
  the copy-code button, and the 10-minute expiry line.
  """

  alias Mithril.Auth.TestPhones
  alias Mithril.Notifications.Outbound
  alias Mithril.ScheduledJobs.MessageDeliveryFallback
  alias Mithril.WhatsApp.ContentSids
  alias Mithril.WhatsApp.Recruitment.Outbound, as: WhatsAppOutbound

  @spec content_sid() :: String.t()
  def content_sid do
    case Application.get_env(:mithril, :twilio_whatsapp_otp_content_sid) do
      sid when is_binary(sid) ->
        trimmed = String.trim(sid)
        if trimmed == "", do: approved_content_sid(), else: trimmed

      _ ->
        approved_content_sid()
    end
  end

  defp approved_content_sid do
    case ContentSids.template("phone_otp") do
      sid when is_binary(sid) and sid != "" ->
        sid

      _ ->
        raise "phone_otp WhatsApp content SID is not configured"
    end
  end

  @spec send(String.t(), String.t()) :: :ok | {:error, atom()}
  def send(phone, code) when is_binary(phone) and is_binary(code) do
    cond do
      TestPhones.configured?(phone) ->
        {:error, :test_phone}

      MessageDeliveryFallback.blocked_recipient?(phone) ->
        {:error, :blocked}

      Application.get_env(:mithril, :otp_whatsapp_delivery, :http) == :test ->
        Application.put_env(:mithril, :test_last_whatsapp_otp, {phone, code})
        :ok

      true ->
        deliver(phone, code)
    end
  end

  defp deliver(phone, code) do
    to = Outbound.whatsapp_address(phone)
    from = Outbound.whatsapp_address(Application.get_env(:mithril, :twilio_whatsapp_from))

    if to == nil or from == nil do
      {:error, :whatsapp_not_configured}
    else
      case WhatsAppOutbound.send_content(to, from, content_sid(), %{"1" => code}, nil, force_from: true) do
        {:ok, _message_sid} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
