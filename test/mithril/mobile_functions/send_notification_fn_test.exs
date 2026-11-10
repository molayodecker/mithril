defmodule Mithril.MobileFunctions.SendNotificationFnTest do
  use ExUnit.Case, async: false

  alias Mithril.MobileFunctions
  alias Mithril.MobileFunctions.SendNotificationFn

  setup do
    previous_sms_adapter = Application.get_env(:mithril, :sms_adapter)
    previous_sms_messages = Application.get_env(:mithril, :test_sms_messages)
    previous_resend_api_key = Application.get_env(:mithril, :resend_api_key)

    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Test)
    Application.put_env(:mithril, :test_sms_messages, [])
    Application.delete_env(:mithril, :resend_api_key)

    on_exit(fn ->
      restore_env(:sms_adapter, previous_sms_adapter)
      restore_env(:test_sms_messages, previous_sms_messages)
      restore_env(:resend_api_key, previous_resend_api_key)
    end)

    :ok
  end

  test "an open notification relay stays forbidden" do
    assert {:error, :forbidden} =
             MobileFunctions.invoke(Ecto.UUID.generate(), "send-notification", %{
               "userId" => Ecto.UUID.generate()
             })
  end

  test "a co-worker invite email is not sent for an address the caller did not invite" do
    assert {:error, :forbidden} =
             SendNotificationFn.call(
               Ecto.UUID.generate(),
               %{
                 "template" => "co_cleaner_invite",
                 "channel" => "sms",
                 "phone" => "+233200000001",
                 "variables" => %{"inviteUrl" => "https://tryinstaclean.com/invite?token=nope"}
               },
               fn _user_id, _template, _body -> :error end
             )
  end

  test "an authorized co-worker invite uses the co-worker message" do
    body = %{
      "template" => "co_cleaner_invite",
      "channel" => "sms",
      "phone" => "+233200000001",
      "variables" => %{
        "inviterName" => "Ama",
        "inviteUrl" => "https://tryinstaclean.com/api/co-cleaner-invite?token=abc",
        "expiresAt" => "2 Nov 2026"
      }
    }

    assert {:ok, %{"smsSent" => true}} =
             SendNotificationFn.call(Ecto.UUID.generate(), body, fn _user_id,
                                                                    _template,
                                                                    allowed ->
               {:ok, allowed}
             end)

    assert [{_, text}] = Application.get_env(:mithril, :test_sms_messages)
    assert text =~ "co-worker"
    refute text =~ "as a co-cleaner"
  end

  test "a matching email cannot authorize a different phone or vice versa" do
    assert SendNotificationFn.invitation_recipient_matches?(
             "invited@example.com",
             nil,
             "invited@example.com",
             "+233200000001"
           )

    refute SendNotificationFn.invitation_recipient_matches?(
             "invited@example.com",
             "+233200000999",
             "invited@example.com",
             "+233200000001"
           )

    refute SendNotificationFn.invitation_recipient_matches?(
             "other@example.com",
             "+233200000001",
             "invited@example.com",
             "+233200000001"
           )

    refute SendNotificationFn.invitation_recipient_matches?(
             nil,
             nil,
             "invited@example.com",
             "+233200000001"
           )
  end

  test "a payout name mismatch report emails the support inbox when no ops list is set" do
    previous = compliance_mail_env()
    Application.put_env(:mithril, :resend_adapter, Mithril.Notifications.Resend.Test)
    Application.put_env(:mithril, :test_resend_messages, [])
    Application.put_env(:mithril, :support_ops_emails, "")
    Application.put_env(:mithril, :support_ops_phones, "")
    Application.put_env(:mithril, :support_ops_slack_webhook_url, "")

    on_exit(fn -> restore_compliance_mail_env(previous) end)

    caller_id = Ecto.UUID.generate()

    assert {:ok, %{"emailSent" => true, "smsSent" => false, "whatsappSent" => false}} =
             SendNotificationFn.call(
               caller_id,
               %{
                 "template" => "payout_name_mismatch_report",
                 "channel" => "email",
                 "email" => "attacker@example.com",
                 "variables" => %{
                   "profileName" => "Ama",
                   "payoutAccountName" => "Boateng",
                   "payoutType" => "mobile_money"
                 }
               },
               fn user_id, "payout_name_mismatch_report", body ->
                 variables = Map.put(body["variables"], "userId", user_id)
                 {:ok, Map.put(body, "variables", variables)}
               end
             )

    assert [message] = Application.get_env(:mithril, :test_resend_messages)
    assert message.to == "support@tryinstaclean.com"
    assert message.subject =~ "Payout name mismatch"
    assert message.text =~ "Ama"
    assert message.text =~ "Boateng"
    assert message.text =~ caller_id
    refute message.text =~ "attacker@example.com"
  end

  test "a configured ops list receives the payout name mismatch report" do
    previous = compliance_mail_env()
    Application.put_env(:mithril, :resend_adapter, Mithril.Notifications.Resend.Test)
    Application.put_env(:mithril, :test_resend_messages, [])
    Application.put_env(:mithril, :support_ops_emails, "ops-review@example.com")
    Application.put_env(:mithril, :support_ops_phones, "")
    Application.put_env(:mithril, :support_ops_slack_webhook_url, "")

    on_exit(fn -> restore_compliance_mail_env(previous) end)

    assert {:ok, %{"emailSent" => true}} =
             SendNotificationFn.call(
               Ecto.UUID.generate(),
               %{
                 "template" => "payout_name_mismatch_report",
                 "channel" => "email",
                 "variables" => %{"profileName" => "Ama", "payoutAccountName" => "Boateng"}
               },
               fn _user_id, _template, body -> {:ok, body} end
             )

    assert [%{to: "ops-review@example.com"}] =
             Application.get_env(:mithril, :test_resend_messages)
  end

  test "invitation URLs use trusted origins and encode stored tokens" do
    url =
      SendNotificationFn.trusted_invite_url("co_cleaner_invite", "abc&next=https://evil.example")

    assert URI.parse(url).host == "tryinstaclean.com"
    assert URI.parse(url).path == "/api/co-cleaner-invite"
    assert URI.decode_query(URI.parse(url).query)["token"] == "abc&next=https://evil.example"
  end

  defp compliance_mail_env do
    %{
      resend_adapter: Application.get_env(:mithril, :resend_adapter),
      test_resend_messages: Application.get_env(:mithril, :test_resend_messages),
      support_ops_emails: Application.get_env(:mithril, :support_ops_emails),
      support_ops_phones: Application.get_env(:mithril, :support_ops_phones),
      support_ops_slack_webhook_url: Application.get_env(:mithril, :support_ops_slack_webhook_url)
    }
  end

  defp restore_compliance_mail_env(previous) do
    restore_env(:resend_adapter, previous.resend_adapter)
    restore_env(:test_resend_messages, previous.test_resend_messages)
    restore_env(:support_ops_emails, previous.support_ops_emails)
    restore_env(:support_ops_phones, previous.support_ops_phones)
    restore_env(:support_ops_slack_webhook_url, previous.support_ops_slack_webhook_url)
  end

  defp restore_env(key, nil), do: Application.delete_env(:mithril, key)
  defp restore_env(key, value), do: Application.put_env(:mithril, key, value)
end
