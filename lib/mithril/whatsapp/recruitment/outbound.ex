defmodule Mithril.WhatsApp.Recruitment.Outbound do
  @moduledoc false

  require Logger

  alias Mithril.WhatsApp.Recruitment.Twiml

  def send_reply(reply, ctx) do
    case reply do
      {:quick, spec} -> send_quick(spec, ctx)
      other -> {:xml, Twiml.xml(other)}
    end
  end

  def send_plain_text(to, from, body) do
    with {:ok, env} <- twilio_env() do
      fields =
        [{"To", to}, {"Body", body}]
        |> maybe_from(env, from)

      post_message(env, fields)
    end
  end

  defp send_quick(spec, ctx) do
    sid = content_sid(spec.template)

    if sid in [nil, ""] do
      {:xml, Twiml.xml({:quick, spec})}
    else
      vars = Jason.encode!(%{"1" => Twiml.content_body(spec.message)})

      with {:ok, env} <- twilio_env() do
        fields =
          [{"To", ctx.to}, {"ContentSid", sid}, {"ContentVariables", vars}]
          |> maybe_from(env, ctx.from)

        case post_message(env, fields) do
          :ok -> {:xml, Twiml.xml(:empty)}
          _ -> {:xml, Twiml.xml({:quick, spec})}
        end
      else
        _ -> {:xml, Twiml.xml({:quick, spec})}
      end
    end
  end

  defp content_sid(:welcome),
    do: Application.get_env(:mithril, :twilio_whatsapp_welcome_content_sid)

  defp content_sid(:yes_no),
    do: Application.get_env(:mithril, :twilio_whatsapp_yes_no_content_sid)

  defp content_sid(:accept),
    do: Application.get_env(:mithril, :twilio_whatsapp_accept_content_sid)

  defp content_sid(:submit),
    do: Application.get_env(:mithril, :twilio_whatsapp_submit_content_sid)

  defp content_sid(:equipment),
    do: Application.get_env(:mithril, :twilio_whatsapp_equipment_content_sid)

  defp content_sid(_), do: nil

  defp twilio_env do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)

    if is_binary(sid) and sid != "" and is_binary(token) and token != "" do
      {:ok,
       %{
         sid: sid,
         token: token,
         messaging_service: Application.get_env(:mithril, :twilio_messaging_service_sid)
       }}
    else
      {:error, :twilio_not_configured}
    end
  end

  defp maybe_from(fields, env, from) do
    if is_binary(env.messaging_service) and env.messaging_service != "" do
      [{"MessagingServiceSid", env.messaging_service} | fields]
    else
      [{"From", from} | fields]
    end
  end

  defp post_message(env, fields) do
    if Application.get_env(:mithril, :twilio_http, :http) == :noop do
      :ok
    else
      post_message_http(env, fields)
    end
  end

  defp post_message_http(env, fields) do
    url = "https://api.twilio.com/2010-04-01/Accounts/#{env.sid}/Messages.json"

    case Req.post(url, form: fields, auth: {:basic, "#{env.sid}:#{env.token}"}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("whatsapp recruitment twilio send failed status=#{status}")
        {:error, :twilio_failed}

      {:error, error} ->
        Logger.warning("whatsapp recruitment twilio send failed #{inspect(error)}")
        {:error, :twilio_failed}
    end
  end
end
