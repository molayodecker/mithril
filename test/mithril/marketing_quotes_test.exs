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
end
