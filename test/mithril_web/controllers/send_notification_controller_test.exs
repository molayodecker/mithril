defmodule MithrilWeb.SendNotificationControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint MithrilWeb.Endpoint
  @path "/functions/v1/send-notification"

  setup do
    previous_token = Application.get_env(:mithril, :send_notification_token)
    previous_sms_adapter = Application.get_env(:mithril, :sms_adapter)
    previous_sms_messages = Application.get_env(:mithril, :test_sms_messages)
    previous_resend_api_key = Application.get_env(:mithril, :resend_api_key)

    Application.put_env(:mithril, :send_notification_token, "reminder-test-token")
    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Test)
    Application.put_env(:mithril, :test_sms_messages, [])
    Application.delete_env(:mithril, :resend_api_key)

    on_exit(fn ->
      restore_env(:send_notification_token, previous_token)
      restore_env(:sms_adapter, previous_sms_adapter)
      restore_env(:test_sms_messages, previous_sms_messages)
      restore_env(:resend_api_key, previous_resend_api_key)
    end)

    :ok
  end

  test "POST /functions/v1/send-notification rejects a missing token" do
    conn = post_json(build_conn(), reminder_body())

    assert %{"error" => "Unauthorized"} = json_response(conn, 401)
  end

  test "POST rejects an incorrect bearer token" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer invalid-token")
      |> post_json(reminder_body())

    assert %{"error" => "Unauthorized"} = json_response(conn, 401)
    assert Application.get_env(:mithril, :test_sms_messages) == []
  end

  test "POST with no recipient does not send notifications" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer reminder-test-token")
      |> post_json(Map.delete(reminder_body(), "phone"))

    assert %{"emailSent" => false, "smsSent" => false, "whatsappSent" => false} =
             json_response(conn, 200)

    assert Application.get_env(:mithril, :test_sms_messages) == []
  end

  test "POST /functions/v1/send-notification sends the booking reminder SMS" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer reminder-test-token")
      |> post_json(reminder_body())

    assert %{"smsSent" => true, "whatsappSent" => false} = json_response(conn, 200)
    assert [{"+233200000001", body}] = Application.get_env(:mithril, :test_sms_messages)
    assert body =~ "Instaclean reminder"
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(body))
  end

  defp reminder_body do
    %{
      "template" => "booking_reminder",
      "channel" => "sms",
      "phone" => "+233200000001",
      "variables" => %{"date" => "2026-10-10", "recipientType" => "customer"}
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:mithril, key)
  defp restore_env(key, value), do: Application.put_env(:mithril, key, value)
end
