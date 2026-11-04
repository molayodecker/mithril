defmodule Mithril.WhatsApp.Recruitment.Outbound do
  @moduledoc false

  require Logger

  alias Mithril.Auth.Phone
  alias Mithril.WhatsApp.ContentSids
  alias Mithril.WhatsApp.Recruitment.Twiml
  alias Mithril.WhatsApp.Unreachable

  def send_reply(reply, ctx) do
    case reply do
      {:quick, spec} -> send_quick(spec, ctx)
      other -> {:xml, Twiml.xml(other)}
    end
  end

  def send_plain_text(to, from, body) do
    with :ok <- guard_reachable(to),
         {:ok, env} <- twilio_env() do
      fields =
        [{"To", to}, {"Body", body}]
        |> maybe_from(from)

      post_message(env, fields)
    end
  end

  @doc """
  Sends an approved WhatsApp content template.

  A non-2xx response whose Twilio code means the number is not on WhatsApp
  is stored and returns `{:error, :not_on_whatsapp}`. A later send to that
  number returns the same error without calling Twilio again.
  """
  def send_content(to, from, content_sid, variables, status_callback_url \\ nil)
      when is_map(variables) do
    with :ok <- guard_reachable(to),
         {:ok, env} <- twilio_env() do
      fields =
        [
          {"To", to},
          {"ContentSid", content_sid},
          {"ContentVariables", Jason.encode!(variables)}
        ]
        |> maybe_from(from)
        |> maybe_status_callback(status_callback_url)

      post_content(env, fields)
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
          |> maybe_from(ctx.from)

        case post_message(env, fields) do
          :ok -> {:xml, Twiml.xml(:empty)}
          _ -> {:xml, Twiml.xml({:quick, spec})}
        end
      else
        _ -> {:xml, Twiml.xml({:quick, spec})}
      end
    end
  end

  defp content_sid(kind) do
    ContentSids.quick_reply(kind) || content_sid_from_env(kind)
  end

  defp content_sid_from_env(:welcome),
    do: Application.get_env(:mithril, :twilio_whatsapp_welcome_content_sid)

  defp content_sid_from_env(:yes_no),
    do: Application.get_env(:mithril, :twilio_whatsapp_yes_no_content_sid)

  defp content_sid_from_env(:accept),
    do: Application.get_env(:mithril, :twilio_whatsapp_accept_content_sid)

  defp content_sid_from_env(:submit),
    do: Application.get_env(:mithril, :twilio_whatsapp_submit_content_sid)

  defp content_sid_from_env(:equipment),
    do: Application.get_env(:mithril, :twilio_whatsapp_equipment_content_sid)

  defp content_sid_from_env(_), do: nil

  defp twilio_env do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)

    if is_binary(sid) and sid != "" and is_binary(token) and token != "" do
      {:ok, %{sid: sid, token: token}}
    else
      {:error, :twilio_not_configured}
    end
  end

  @doc false
  def sender_fields(from) do
    []
    |> put_sender("From", from)
    |> put_sender("MessagingServiceSid", messaging_service_for(from))
  end

  defp maybe_from(fields, from) do
    sender_fields(from) ++ fields
  end

  defp put_sender(fields, _key, value) when value in [nil, ""], do: fields
  defp put_sender(fields, key, value) when is_binary(value), do: fields ++ [{key, value}]

  # The admin line and the main WhatsApp line live in different Messaging
  # Services. A number listed as both stays on the main service.
  defp messaging_service_for(from) do
    cond do
      listed_sender?(from, :twilio_whatsapp_admin_from) and
          not listed_sender?(from, :twilio_whatsapp_from) ->
        configured(:twilio_whatsapp_admin_messaging_service_sid)

      listed_sender?(from, :twilio_whatsapp_from) ->
        configured(:twilio_whatsapp_messaging_service_sid)

      true ->
        nil
    end
  end

  defp listed_sender?(from, key) do
    case canonical(from) do
      {:ok, e164} ->
        Application.get_env(:mithril, key, "")
        |> to_string()
        |> String.split(",")
        |> Enum.any?(fn candidate -> canonical(candidate) == {:ok, e164} end)

      :error ->
        false
    end
  end

  defp canonical(value) when is_binary(value) do
    value
    |> String.replace(~r/^whatsapp:/i, "")
    |> Phone.normalize()
  end

  defp canonical(_), do: :error

  defp configured(key) do
    case Application.get_env(:mithril, key) do
      sid when is_binary(sid) and sid != "" -> sid
      _ -> nil
    end
  end

  defp maybe_status_callback(fields, url) when is_binary(url) and url != "",
    do: [{"StatusCallback", url} | fields]

  defp maybe_status_callback(fields, _), do: fields

  defp post_message(env, fields) do
    case Application.get_env(:mithril, :twilio_http, :http) do
      :noop -> :ok
      {:error, reason} -> {:error, reason}
      _ -> post_message_http(env, fields)
    end
  end

  defp post_content(env, fields) do
    case Application.get_env(:mithril, :twilio_http, :http) do
      :noop -> {:ok, "SMtest-payment-request"}
      {:error, reason} -> {:error, reason}
      _ -> post_content_http(env, fields)
    end
  end

  defp post_message_http(env, fields) do
    url = "https://api.twilio.com/2010-04-01/Accounts/#{env.sid}/Messages.json"

    case Req.post(url, form: fields, auth: {:basic, "#{env.sid}:#{env.token}"}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        classify_rejection(fields, body, status, :twilio_failed)

      {:error, error} ->
        Logger.warning("whatsapp recruitment twilio send failed #{inspect(error)}")
        {:error, :twilio_failed}
    end
  end

  defp post_content_http(env, fields) do
    url = "https://api.twilio.com/2010-04-01/Accounts/#{env.sid}/Messages.json"

    case Req.post(url, form: fields, auth: {:basic, "#{env.sid}:#{env.token}"}) do
      {:ok, %{status: status, body: %{"sid" => sid}}}
      when status in 200..299 and is_binary(sid) and sid != "" ->
        {:ok, sid}

      {:ok, %{status: status}} when status in 200..299 ->
        {:error, :twilio_unavailable}

      {:ok, %{status: status, body: body}} ->
        classify_rejection(fields, body, status, :twilio_rejected)

      {:error, error} ->
        Logger.warning("whatsapp template send unavailable #{inspect(error)}")
        {:error, :twilio_unavailable}
    end
  end

  defp guard_reachable(to) do
    case Unreachable.phone(to) do
      {:ok, phone} ->
        if Unreachable.unreachable?(phone), do: {:error, :not_on_whatsapp}, else: :ok

      :error ->
        :ok
    end
  end

  defp classify_rejection(fields, body, status, fallback) do
    case Unreachable.remember(to_address(fields), body) do
      :recorded ->
        {:error, :not_on_whatsapp}

      :ignored ->
        Logger.warning("whatsapp twilio send failed status=#{status} body=#{inspect(body)}")
        {:error, fallback}
    end
  end

  defp to_address(fields) do
    Enum.find_value(fields, fn
      {"To", value} -> value
      _ -> nil
    end)
  end
end
