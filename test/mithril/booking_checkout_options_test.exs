defmodule Mithril.BookingCheckoutOptionsTest do
  use ExUnit.Case, async: false

  alias Mithril.MobileFunctions
  alias Mithril.MobileGateway

  setup do
    previous_gate = Application.get_env(:mithril, :stripe_booking_checkout_env_gate)
    previous_key = Application.get_env(:mithril, :posthog_project_api_key)
    previous_stripe_secret = Application.get_env(:mithril, :stripe_secret_key)

    on_exit(fn ->
      restore(:stripe_booking_checkout_env_gate, previous_gate)
      restore(:posthog_project_api_key, previous_key)
      restore(:stripe_secret_key, previous_stripe_secret)
    end)

    :ok
  end

  test "hides Stripe when the server kill switch is off" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :off)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    user_id = Ecto.UUID.generate()

    assert {:ok, body} =
             MobileFunctions.invoke(user_id, "booking-checkout-options", %{
               "booking_id" => Ecto.UUID.generate(),
               "client_platform" => "ios"
             })

    assert body.paystack_available == true
    assert body.stripe_available == false
    assert body.stripe_unavailable_reason == "stripe_disabled"
  end

  test "shows Stripe for native clients when configured and enabled" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :on)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    user_id = Ecto.UUID.generate()

    assert {:ok, body} =
             MobileFunctions.invoke(user_id, "booking-checkout-options", %{
               "client_platform" => "ios"
             })

    assert body.paystack_available == true
    assert body.stripe_available == true
    assert is_nil(body.stripe_unavailable_reason)
  end

  test "hides Stripe for web clients even when configured and enabled" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :on)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    user_id = Ecto.UUID.generate()

    assert {:ok, body} =
             MobileFunctions.invoke(user_id, "booking-checkout-options", %{
               "clientPlatform" => "web"
             })

    assert body.stripe_available == false
    assert body.stripe_unavailable_reason == "web_unsupported"
  end

  test "hides Stripe when the env gate is unset and PostHog has no project key" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :unset)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    Application.delete_env(:mithril, :posthog_project_api_key)
    user_id = Ecto.UUID.generate()

    assert {:ok, body} = MobileGateway.invoke_function(user_id, "booking-checkout-options", %{})

    assert body.stripe_available == false
    assert body.stripe_unavailable_reason == "stripe_disabled"
  end

  defp restore(key, nil), do: Application.delete_env(:mithril, key)
  defp restore(key, value), do: Application.put_env(:mithril, key, value)
end
