defmodule MithrilWeb.WhatsAppRecruitmentControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mithril.WhatsApp.Recruitment.Leads

  @endpoint MithrilWeb.Endpoint
  @auth_token "test-twilio-auth-token"
  @url "https://api.tryinstaclean.com/whatsapp/join-as-cleaner-bot"
  @alias_url "https://api.tryinstaclean.com/functions/v1/join-as-cleaner-bot"

  setup do
    Leads.Memory.reset()
    :ok
  end

  test "POST APPLY returns TwiML on the Mithril webhook path" do
    params = twilio_params("APPLY")

    conn =
      build_conn()
      |> put_req_header("x-twilio-signature", sign(params, @url))
      |> post("/whatsapp/join-as-cleaner-bot", params)

    assert conn.status == 200
    assert conn.resp_headers |> Enum.any?(fn {k, v} -> k == "content-type" and String.contains?(v, "xml") end)
    assert conn.resp_body =~ "What is your email address?"
  end

  test "POST APPLY also works on the Edge Function alias path" do
    params = twilio_params("HELP")

    conn =
      build_conn()
      |> put_req_header("x-twilio-signature", sign(params, @alias_url))
      |> post("/functions/v1/join-as-cleaner-bot", params)

    assert conn.status == 200
    assert conn.resp_body =~ "My name is Rosie"
  end

  test "rejects unsigned Twilio posts" do
    conn = post(build_conn(), "/whatsapp/join-as-cleaner-bot", twilio_params("APPLY"))
    assert conn.status == 401
  end

  defp twilio_params(body) do
    %{
      "AccountSid" => "ACtestrecruitment",
      "Body" => body,
      "From" => "whatsapp:+233555000222",
      "To" => "whatsapp:+233246326939"
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
