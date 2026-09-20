defmodule Mithril.WhatsApp.Recruitment do
  @moduledoc """
  WhatsApp cleaner recruitment bot, ported from the `join-as-cleaner-bot`
  / `whatsapp-bot` Edge Function.
  """

  require Logger

  alias Mithril.WhatsApp.Recruitment.Conversation
  alias Mithril.WhatsApp.Recruitment.GhanaCard
  alias Mithril.WhatsApp.TwilioSignature

  def configured? do
    present?(Application.get_env(:mithril, :twilio_account_sid)) and
      present?(Application.get_env(:mithril, :twilio_auth_token)) and
      present?(Application.get_env(:mithril, :twilio_webhook_url))
  end

  def handle_webhook(params, signature) do
    cond do
      not configured?() ->
        {:error, :not_configured}

      not valid_signature?(params, signature) ->
        {:error, :unauthorized}

      true ->
        {:ok, Conversation.handle(params)}
    end
  end

  def handle_ghana_get(token) when not is_binary(token) or token == "" do
    {:error, :missing_token}
  end

  def handle_ghana_get(token) do
    case GhanaCard.verify_token(token) do
      {:ok, payload} ->
        origin =
          Application.get_env(:mithril, :app_url, "https://tryinstaclean.com")
          |> String.trim_trailing("/")

        encoded = URI.encode_www_form(token)
        {:redirect, "#{origin}#{GhanaCard.upload_page_path()}?t=#{encoded}&side=#{payload.side}"}

      :error ->
        {:error, :unauthorized}
    end
  end

  def handle_ghana_post(params) do
    GhanaCard.handle_browser_upload(params)
  end

  defp valid_signature?(params, signature) do
    if skip_signature?() do
      Logger.warning("Twilio signature validation DISABLED (non-production only)")
      true
    else
      Enum.any?(webhook_urls(), fn url ->
        TwilioSignature.valid?(
          string_params(params),
          signature,
          Application.get_env(:mithril, :twilio_auth_token),
          url
        )
      end)
    end
  end

  defp skip_signature? do
    Application.get_env(:mithril, :disable_twilio_signature_validation, false)
  end

  defp webhook_urls do
    [
      Application.get_env(:mithril, :twilio_webhook_url),
      Application.get_env(:mithril, :twilio_webhook_url_alias)
    ]
    |> Enum.filter(&present?/1)
  end

  defp string_params(params) do
    params
    |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
