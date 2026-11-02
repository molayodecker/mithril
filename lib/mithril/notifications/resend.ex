defmodule Mithril.Notifications.Resend do
  @moduledoc false

  require Logger

  def deliver(%{to: to, subject: subject, html: html, text: text})
      when is_binary(to) and is_binary(subject) and is_binary(html) and is_binary(text) do
    adapter().deliver(%{to: to, subject: subject, html: html, text: text})
  end

  def deliver(_message), do: {:error, :email_delivery_failed}

  defp adapter do
    Application.get_env(:mithril, :resend_adapter, Mithril.Notifications.Resend.HTTP)
  end
end

defmodule Mithril.Notifications.Resend.Test do
  @moduledoc false

  def deliver(message) do
    messages = Application.get_env(:mithril, :test_resend_messages, [])
    Application.put_env(:mithril, :test_resend_messages, [message | messages])
    :ok
  end
end

defmodule Mithril.Notifications.Resend.HTTP do
  @moduledoc false

  require Logger

  def deliver(%{to: to, subject: subject, html: html, text: text}) do
    api_key = Application.get_env(:mithril, :resend_api_key, "") |> to_string() |> String.trim()

    if api_key == "" do
      {:error, :email_not_configured}
    else
      from =
        Application.get_env(
          :mithril,
          :resend_from,
          "Instaclean <noreply@update.tryinstaclean.com>"
        )

      body = %{
        from: from,
        to: [to],
        subject: subject,
        html: html,
        text: text
      }

      options = [json: body, auth: {:bearer, api_key}]
      extra = Application.get_env(:mithril, :resend_req_options, [])
      options = if is_list(extra), do: Keyword.merge(options, extra), else: options
      url = Application.get_env(:mithril, :resend_api_url, "https://api.resend.com/emails")

      case Req.post(url, options) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          Logger.warning("Resend rejected an email with status #{status}")
          {:error, :email_delivery_failed}

        {:error, reason} ->
          Logger.warning("Resend request failed: #{inspect(reason)}")
          {:error, :email_delivery_failed}
      end
    end
  end
end
