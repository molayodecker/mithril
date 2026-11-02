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

  defp restore_env(key, nil), do: Application.delete_env(:mithril, key)
  defp restore_env(key, value), do: Application.put_env(:mithril, key, value)
end
