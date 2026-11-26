defmodule Mithril.Twilio.MessageLogTest do
  use ExUnit.Case, async: false

  alias Mithril.Twilio.MessageLog

  setup do
    previous = Application.get_env(:mithril, :twilio_req_options)

    Application.put_env(:mithril, :twilio_req_options,
      plug: {Req.Test, Mithril.Twilio.MessageLog}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:mithril, :twilio_req_options, previous)
      else
        Application.delete_env(:mithril, :twilio_req_options)
      end
    end)

    :ok
  end

  test "reads Twilio's message page and drops the account identifier" do
    Req.Test.stub(Mithril.Twilio.MessageLog, fn conn ->
      assert conn.request_path == "/2010-04-01/Accounts/ACtestrecruitment/Messages.json"
      assert conn.query_string =~ "PageSize=50"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "messages" => [
            %{
              "sid" => "SM123",
              "account_sid" => "ACtestrecruitment",
              "from" => "+15550001111",
              "to" => "whatsapp:+233200000000",
              "body" => "Cleaner is on the way",
              "status" => "delivered",
              "direction" => "outbound-api",
              "error_code" => nil,
              "error_message" => nil,
              "date_sent" => "Thu, 26 Nov 2026 16:00:00 +0000",
              "date_created" => "Thu, 26 Nov 2026 16:00:01 +0000",
              "num_segments" => "1",
              "uri" => "/2010-04-01/Accounts/ACtestrecruitment/Messages/SM123.json"
            }
          ],
          "next_page_uri" =>
            "/2010-04-01/Accounts/ACtestrecruitment/Messages.json?PageToken=PA123&Page=1"
        })
      )
    end)

    assert {:ok, page} = MessageLog.fetch_page(%{})

    assert page.nextPageToken == "PA123"
    assert [message] = page.messages
    assert message.sid == "SM123"
    assert message.to == "whatsapp:+233200000000"
    assert message.body == "Cleaner is on the way"
    refute Map.has_key?(message, :account_sid)
    refute Map.has_key?(message, :uri)
  end

  test "rejects a page token that is not a Twilio token" do
    assert MessageLog.query_params(%{"pageToken" => "../Messages"}) ==
             {:error, :invalid_request}
  end

  test "rejects a page size outside 1..100" do
    assert MessageLog.query_params(%{"pageSize" => "500"}) == {:error, :invalid_request}
  end

  test "a caller who is not staff cannot read the log" do
    assert MessageLog.list("00000000-0000-4000-8000-000000000000", %{}) == {:error, :forbidden}
  end
end
