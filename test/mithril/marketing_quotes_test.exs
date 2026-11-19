defmodule Mithril.MarketingQuotesTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mithril.MarketingQuotes

  @endpoint MithrilWeb.Endpoint

  setup do
    Application.put_env(:mithril, :test_resend_messages, [])
    Application.put_env(:mithril, :marketing_quote_template, :plain)

    on_exit(fn ->
      Application.delete_env(:mithril, :marketing_quote_template)
    end)

    :ok
  end

  test "emails support and accepts a quote without a template" do
    assert {:ok, :accepted} =
             MarketingQuotes.submit(%{
               "name" => "Ama",
               "phone" => "0240000000",
               "serviceType" => "Deep cleaning",
               "location" => "East Legon",
               "frequency" => "One visit"
             })

    assert [%{to: "support@tryinstaclean.com", subject: "Instaclean quote request", text: text}] =
             Application.get_env(:mithril, :test_resend_messages)

    assert text =~ "Name: Ama"
    assert text =~ "Service: Deep cleaning"
  end

  test "POST /direct/quotes accepts the same quote" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/direct/quotes", %{
        "name" => "Ama",
        "phone" => "0240000000",
        "serviceType" => "Deep cleaning",
        "location" => "East Legon"
      })

    assert json_response(conn, 200) == %{"ok" => true}
  end

  test "POST /direct/quotes rejects an incomplete quote" do
    conn = post(build_conn(), "/direct/quotes", %{})
    assert json_response(conn, 422) == %{"ok" => false, "error" => "invalid_quote"}
  end
  test "accepts emailed quote when WhatsApp is unavailable" do
    previous = Application.get_env(:mithril, :twilio_http)
    Application.put_env(:mithril, :twilio_http, {:error, :twilio_unavailable})

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:mithril, :twilio_http),
        else: Application.put_env(:mithril, :twilio_http, previous)
    end)

    assert {:ok, :accepted} =
             MarketingQuotes.submit(%{
               "name" => "Ama",
               "phone" => "0240000000",
               "serviceType" => "Deep cleaning",
               "location" => "East Legon"
             })

    assert [_email] = Application.get_env(:mithril, :test_resend_messages)
  end

  test "limits public quote requests per peer IP" do
    ip = {10, 23, 45, 67}
    params = %{"company_website" => "bot.example"}

    for _ <- 1..5 do
      conn = build_conn() |> Map.put(:remote_ip, ip) |> post("/direct/quotes", params)
      assert json_response(conn, 200) == %{"ok" => true}
    end

    conn = build_conn() |> Map.put(:remote_ip, ip) |> post("/direct/quotes", params)
    assert json_response(conn, 429) == %{"ok" => false, "error" => "rate_limited"}
  end

end
