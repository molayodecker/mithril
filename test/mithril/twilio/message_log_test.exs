defmodule Mithril.Twilio.MessageLogTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.Twilio.MessageLog
  alias MithrilWeb.DirectAdminTwilioController
  alias MithrilWeb.Plugs.DirectOpsAuthorization

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

  test "only the messaging desk grant allows scoped staff to read Twilio history" do
    :ok = Sandbox.checkout(Repo)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    messaging_user = grant_desk!("whatsapp_inbox")
    bookings_user = grant_desk!("bookings")

    Req.Test.expect(MessageLog, fn conn ->
      Req.Test.json(conn, %{"messages" => [%{"sid" => "SM123"}]})
    end)

    denied = request_messages(bookings_user)
    assert denied.status == 403
    assert denied.halted

    allowed = request_messages(messaging_user)
    assert allowed.status == 200
    assert %{"messages" => [%{"sid" => "SM123"}]} = Jason.decode!(allowed.resp_body)
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
  defp grant_desk!(desk) do
    user_id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1::uuid, $2)", [
      Ecto.UUID.dump!(user_id),
      desk
    ])

    user_id
  end

  defp request_messages(user_id) do
    conn =
      :get
      |> Plug.Test.conn("/direct/admin/twilio/messages")
      |> Plug.Conn.assign(:instaclean_user_id, user_id)
      |> DirectOpsAuthorization.call([])

    if conn.halted, do: conn, else: DirectAdminTwilioController.messages(conn, %{})
  end
end
