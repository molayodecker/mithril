defmodule Mithril.WhatsApp.RecruitmentTest do
  use ExUnit.Case, async: false

  alias Mithril.WhatsApp.Recruitment
  alias Mithril.WhatsApp.Recruitment.Leads

  @auth_token "test-twilio-auth-token"
  @url "https://api.tryinstaclean.com/whatsapp/join-as-cleaner-bot"
  @from "whatsapp:+233555000111"
  @to "whatsapp:+233246326939"

  setup do
    Leads.Memory.reset()
    :ok
  end

  test "APPLY starts the email step" do
    {:ok, xml} = Recruitment.handle_webhook(signed_params("APPLY"), sign(signed_params("APPLY")))

    assert xml =~ "What is your email address?"
    assert {:ok, lead} = Leads.get_or_create("+233555000111")
    assert lead.current_step == "personal_email"
  end

  test "ignores the customer-support WhatsApp line" do
    params =
      signed_params("APPLY")
      |> Map.put("To", "whatsapp:+233559100642")

    {:ok, xml} = Recruitment.handle_webhook(params, sign(params))

    assert xml =~ "customer support"
    refute xml =~ "What is your email address?"
  end

  test "rejects an invalid Twilio signature" do
    assert {:error, :unauthorized} =
             Recruitment.handle_webhook(signed_params("APPLY"), "not-a-real-signature")
  end

  test "skips in-flight Ghana Card steps and continues at terms" do
    {:ok, lead} = Leads.get_or_create("+233555000111")

    :ok =
      Leads.persist(lead.phone, %{
        current_step: "ghana_card_front",
        step: "ghana_card_front",
        step_history: ["international_languages", "ghana_card_front"]
      })

    params = signed_params("CONTINUE")
    {:ok, xml} = Recruitment.handle_webhook(params, sign(params))

    assert xml =~ "Agree to Terms"
    refute xml =~ "Ghana Card"
    assert {:ok, updated} = Leads.get_or_create("+233555000111")
    assert updated.current_step == "terms_agreement"
    refute "ghana_card_front" in updated.step_history
  end

  defp signed_params(body) do
    %{
      "AccountSid" => "ACtestrecruitment",
      "Body" => body,
      "From" => @from,
      "To" => @to
    }
  end

  defp sign(params) do
    payload =
      params
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(@url, fn {key, value}, acc -> acc <> key <> value end)

    :crypto.mac(:hmac, :sha, @auth_token, payload) |> Base.encode64()
  end
end
