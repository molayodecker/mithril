defmodule Mithril.WhatsApp.TwilioSignatureTest do
  use ExUnit.Case, async: true

  alias Mithril.WhatsApp.TwilioSignature

  @auth_token "test-twilio-auth-token"
  @url "https://api.tryinstaclean.com/whatsapp/join-as-cleaner-bot"

  test "rejects a missing signature" do
    refute TwilioSignature.valid?(%{"Body" => "APPLY"}, nil, @auth_token, @url)
    refute TwilioSignature.valid?(%{"Body" => "APPLY"}, "", @auth_token, @url)
  end

  test "accepts a signature over the webhook URL plus sorted params" do
    params = %{
      "Body" => "APPLY",
      "From" => "whatsapp:+233555000001",
      "To" => "whatsapp:+233246326939"
    }

    signature = sign(params, @url)

    assert TwilioSignature.valid?(params, signature, @auth_token, @url)
    refute TwilioSignature.valid?(params, signature, @auth_token, @url <> "/")
    refute TwilioSignature.valid?(Map.put(params, "Body", "HELP"), signature, @auth_token, @url)
  end

  test "is independent of param insertion order" do
    left = %{"To" => "whatsapp:+233246326939", "Body" => "APPLY", "From" => "whatsapp:+233555000001"}
    right = %{"From" => "whatsapp:+233555000001", "Body" => "APPLY", "To" => "whatsapp:+233246326939"}

    assert TwilioSignature.valid?(right, sign(left, @url), @auth_token, @url)
  end

  defp sign(params, url) do
    payload =
      params
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(url, fn {key, value}, acc -> acc <> key <> value end)

    :crypto.mac(:hmac, :sha, @auth_token, payload) |> Base.encode64()
  end
end
