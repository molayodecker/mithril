defmodule Mithril.SupportOps do
  @moduledoc false

  require Logger

  alias Mithril.Auth.SMS

  @slack_prefix "https://hooks.slack.com/"
  @slack_body_max 2900
  @sms_max 320

  @type notify_result :: %{
          email_sent: boolean(),
          sms_sent: integer(),
          slack_sent: boolean(),
          sms_skipped: boolean()
        }

  @spec notify(%{subject: String.t(), plain_body: String.t()}) :: notify_result
  def notify(%{subject: subject, plain_body: plain_body}) do
    email_sent = send_ops_emails(subject, plain_body)
    slack_sent = send_slack(plain_body)
    sms_sent = send_ops_sms_if_needed(plain_body, email_sent, slack_sent)

    %{
      email_sent: email_sent,
      sms_sent: sms_sent,
      slack_sent: slack_sent,
      sms_skipped: sms_sent == 0 and not sms_enabled?()
    }
  end

  @spec delivered?(notify_result()) :: boolean()
  def delivered?(result) do
    result.email_sent or result.slack_sent or result.sms_sent > 0
  end

  @spec send_slack(String.t()) :: boolean()
  def send_slack(body) when is_binary(body) do
    webhook = slack_webhook_url()

    if webhook == nil do
      false
    else
      payload = %{
        text: body |> String.trim() |> String.slice(0, @slack_body_max)
      }

      case Req.post(webhook, json: payload) do
        {:ok, %{status: status}} when status in 200..299 ->
          true

        {:ok, %{status: status, body: response_body}} ->
          Logger.warning(
            "support_ops slack failed status=#{status} body=#{inspect(response_body)}"
          )

          false

        {:error, error} ->
          Logger.warning("support_ops slack error=#{inspect(error)}")
          false
      end
    end
  end

  defp send_ops_emails(subject, plain_body) do
    emails = ops_emails()

    if emails == [] or resend_api_key() == nil do
      false
    else
      emails
      |> Enum.any?(fn email ->
        case Req.post(
               "https://api.resend.com/emails",
               json: %{
                 from: resend_from(),
                 to: [email],
                 subject: subject,
                 html: "<pre>#{html_escape(plain_body)}</pre>"
               },
               auth: {:bearer, resend_api_key()}
             ) do
          {:ok, %{status: status}} when status in 200..299 -> true
          _ -> false
        end
      end)
    end
  end

  defp send_ops_sms_if_needed(body, email_sent, slack_sent) do
    cond do
      not sms_enabled?() ->
        0

      sms_fallback_only?() and (email_sent or slack_sent) ->
        0

      true ->
        phones = ops_phones()

        phones
        |> Enum.count(fn phone ->
          SMS.send_message(phone, truncate_sms(body)) == :ok
        end)
    end
  end

  defp truncate_sms(body) do
    trimmed = String.trim(body)

    if String.length(trimmed) <= @sms_max do
      trimmed
    else
      String.slice(trimmed, 0, @sms_max - 1) <> "…"
    end
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp slack_webhook_url do
    env = fn name ->
      case Application.get_env(:mithril, name) || System.get_env(to_string(name)) do
        value when is_binary(value) ->
          value
          |> String.trim()
          |> then(fn trimmed -> if trimmed == "", do: nil, else: trimmed end)

        _ ->
          nil
      end
    end

    url = env.(:support_ops_slack_webhook_url) || env.(:slack_ops_webhook_url)

    if is_binary(url) and String.starts_with?(url, @slack_prefix), do: url, else: nil
  end

  defp ops_emails do
    parse_list(
      Application.get_env(:mithril, :support_ops_emails) ||
        System.get_env("SUPPORT_OPS_EMAILS") ||
        System.get_env("CLEANER_APPLICATION_OPS_EMAILS")
    )
  end

  defp ops_phones do
    parse_list(
      Application.get_env(:mithril, :support_ops_phones) ||
        System.get_env("SUPPORT_OPS_PHONES") ||
        System.get_env("CLEANER_APPLICATION_OPS_PHONES")
    )
  end

  defp parse_list(nil), do: []

  defp parse_list(raw) when is_binary(raw) do
    raw
    |> String.split(~r/[,;]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_list(_), do: []

  defp resend_api_key, do: Application.get_env(:mithril, :resend_api_key)

  defp resend_from do
    Application.get_env(:mithril, :resend_from, "Instaclean <noreply@update.tryinstaclean.com>")
  end

  defp sms_enabled? do
    Application.get_env(:mithril, :support_ops_sms_enabled, true) not in [false, "false", "0", 0]
  end

  defp sms_fallback_only? do
    Application.get_env(:mithril, :support_ops_sms_fallback_only, true) not in [
      false,
      "false",
      "0",
      0
    ]
  end
end
