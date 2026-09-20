defmodule Mithril.WhatsApp.TwilioSignature do
  @moduledoc """
  Twilio request signature check used by the recruitment WhatsApp webhook.
  """

  @spec valid?(map(), String.t() | nil, String.t(), String.t()) :: boolean()
  def valid?(_params, signature, _auth_token, _webhook_url)
      when not is_binary(signature) or signature == "",
      do: false

  def valid?(params, signature, auth_token, webhook_url)
      when is_binary(signature) and is_binary(auth_token) and is_binary(webhook_url) do
    payload =
      params
      |> Enum.map(fn {key, value} -> {to_string(key), stringify(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(webhook_url, fn {key, value}, acc -> acc <> key <> value end)

    expected =
      :crypto.mac(:hmac, :sha, auth_token, payload)
      |> Base.encode64()

    Plug.Crypto.secure_compare(expected, signature)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_number(value), do: to_string(value)
  defp stringify(true), do: "true"
  defp stringify(false), do: "false"
  defp stringify(value), do: to_string(value)
end
