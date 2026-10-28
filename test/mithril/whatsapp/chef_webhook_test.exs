defmodule Mithril.WhatsApp.ChefWebhookTest do
  use ExUnit.Case, async: false

  alias Mithril.Repo
  alias Mithril.WhatsApp.ChefWebhook

  @auth_token "test-twilio-auth-token"
  @url "https://api.tryinstaclean.com/whatsapp/chef-intake"
  @alias_url "https://api.tryinstaclean.com/functions/v1/chef-intake"
  @from "whatsapp:+233555000333"
  @chef_to "whatsapp:+233200000001"
  @recruitment_to "whatsapp:+233246326939"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Mithril.Repo)
    :ok
  end

  test "a first message on the chef line starts the enquiry" do
    params = twilio_params("Hi", "SM_chef_start")

    assert {:ok, xml} = ChefWebhook.handle(params, sign(params, @url))
    assert xml =~ "Instaclean Chef Services"
    assert xml =~ "Which area"
  end

  test "accepts the chef-intake alias signature" do
    params = twilio_params("CHEF", "SM_chef_alias")

    assert {:ok, xml} = ChefWebhook.handle(params, sign(params, @alias_url))
    assert xml =~ "Instaclean Chef Services"
  end

  test "APPLY on the chef line points at the cleaner recruitment bot" do
    params = twilio_params("APPLY", "SM_chef_apply")

    assert {:ok, xml} = ChefWebhook.handle(params, sign(params, @url))
    assert xml =~ "for chef enquiries"
    assert xml =~ "https://wa.me/233246326939"
    refute xml =~ "Instaclean Chef Services"
  end

  test "rejects traffic addressed to the recruitment sender" do
    params = twilio_params("CHEF", "SM_chef_wrong_to") |> Map.put("To", @recruitment_to)

    assert {:error, :invalid_request} = ChefWebhook.handle(params, sign(params, @url))
  end

  test "does not advance on a Twilio retry of the same MessageSid" do
    first = twilio_params("Accra", "SM_chef_retry")
    assert {:ok, xml} = ChefWebhook.handle(first, sign(first, @url))
    assert xml =~ "Which area"

    second = twilio_params("Accra", "SM_chef_retry")
    assert {:ok, retry} = ChefWebhook.handle(second, sign(second, @url))
    assert retry =~ "<Response></Response>"

    [[step]] =
      Repo.query!("SELECT step FROM public.whatsapp_chef_intakes WHERE phone = $1", [@from]).rows

    assert step == 0
  end

  test "rejects an invalid Twilio signature" do
    assert {:error, :unauthorized} =
             ChefWebhook.handle(twilio_params("CHEF", "SM_chef_bad_sig"), "not-a-real-signature")
  end

  defp twilio_params(body, sid) do
    %{
      "AccountSid" => "ACtestrecruitment",
      "Body" => body,
      "From" => @from,
      "To" => @chef_to,
      "MessageSid" => sid
    }
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
