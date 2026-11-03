defmodule Mithril.WhatsApp.ContentApi do
  @moduledoc false

  require Logger

  def create(payload) when is_map(payload) do
    request(:create, payload, "https://content.twilio.com/v1/Content")
  end

  def submit_approval(content_sid, name) when is_binary(content_sid) and is_binary(name) do
    request(
      :approve,
      %{"name" => name, "category" => "UTILITY"},
      "https://content.twilio.com/v1/Content/#{content_sid}/ApprovalRequests/whatsapp"
    )
  end

  defp request(action, payload, url) do
    case Application.get_env(:mithril, :twilio_content_http, :http) do
      fun when is_function(fun, 2) ->
        fun.(action, payload)

      _ ->
        post(url, payload)
    end
  end

  defp post(url, payload) do
    with {:ok, env} <- twilio_env() do
      case Req.post(url, json: payload, auth: {:basic, "#{env.sid}:#{env.token}"}) do
        {:ok, %{status: status, body: %{"sid" => content_sid}}}
        when status in 200..299 and is_binary(content_sid) ->
          {:ok, content_sid}

        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "whatsapp content template request failed status=#{status} body=#{inspect(body)}"
          )

          {:error, :template_not_created}

        {:error, error} ->
          Logger.warning("whatsapp content template request failed #{inspect(error)}")
          {:error, :template_not_created}
      end
    end
  end

  defp twilio_env do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)

    if is_binary(sid) and sid != "" and is_binary(token) and token != "" do
      {:ok, %{sid: sid, token: token}}
    else
      {:error, :twilio_not_configured}
    end
  end
end
