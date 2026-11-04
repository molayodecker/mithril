defmodule Mithril.WhatsApp.ContentTemplateTest do
  use ExUnit.Case, async: false

  alias Mithril.WhatsApp.ContentTemplate

  @name "instaclean_content_template_test"
  @env_key :twilio_template_content_template_test

  setup do
    previous_env = Application.get_env(:mithril, @env_key)
    previous_http = Application.get_env(:mithril, :twilio_content_http)

    on_exit(fn ->
      restore_env(@env_key, previous_env)
      restore_env(:twilio_content_http, previous_http)
    end)

    Application.delete_env(:mithril, @env_key)
    :ok
  end

  test "ensure reuses an env Content SID" do
    Application.put_env(:mithril, @env_key, "HXfromenv000000000000000000000001")

    assert {:ok, "HXfromenv000000000000000000000001"} =
             ContentTemplate.ensure(@name, @env_key, %{"friendly_name" => @name})
  end

  test "ensure rejects template creation when its SID cannot be stored" do
    parent = self()

    Application.put_env(:mithril, :twilio_content_http, fn
      :create, payload ->
        send(parent, {:create, payload})
        {:ok, "HXcreated00000000000000000000001"}

      :approve, payload ->
        send(parent, {:approve, payload})
        :ok
    end)

    assert {:error, :template_storage_unavailable} =
             ContentTemplate.ensure(@name, @env_key, %{"friendly_name" => @name})

    assert_receive {:create, %{"friendly_name" => @name}}
    refute_receive {:approve, _}
    assert ContentTemplate.content_sid(@name, @env_key) == nil
  end

  defp restore_env(key, nil), do: Application.delete_env(:mithril, key)
  defp restore_env(key, value), do: Application.put_env(:mithril, key, value)
end
