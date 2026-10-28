defmodule MithrilWeb.WhatsAppChefControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint
  @auth_token "test-twilio-auth-token"
  @url "https://api.tryinstaclean.com/whatsapp/chef-intake"
  @alias_url "https://api.tryinstaclean.com/functions/v1/chef-intake"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Mithril.Repo)
    :ok
  end

  test "POST CHEF returns TwiML on the chef webhook path" do
    params = twilio_params("CHEF", "SM_chef_http")

    conn =
      build_conn()
      |> put_req_header("x-twilio-signature", sign(params, @url))
      |> post("/whatsapp/chef-intake", params)

    assert conn.status == 200
    assert conn.resp_body =~ "Instaclean Chef Services"
  end

  test "POST also works on the chef alias path" do
    params = twilio_params("hello", "SM_chef_http_alias")

    conn =
      build_conn()
      |> put_req_header("x-twilio-signature", sign(params, @alias_url))
      |> post("/functions/v1/chef-intake", params)

    assert conn.status == 200
    assert conn.resp_body =~ "Which area"
  end

  test "rejects unsigned Twilio posts" do
    conn =
      post(build_conn(), "/whatsapp/chef-intake", twilio_params("CHEF", "SM_chef_http_unsigned"))

    assert conn.status == 401
  end

  defp twilio_params(body, sid) do
    %{
      "AccountSid" => "ACtestrecruitment",
      "Body" => body,
      "From" => "whatsapp:+233555000444",
      "To" => "whatsapp:+233200000001",
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
