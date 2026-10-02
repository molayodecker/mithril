defmodule Mithril.BookingCheckoutOptionsTest do
  use ExUnit.Case, async: false

  alias Mithril.MobileFunctions
  alias Mithril.MobileGateway
  alias Mithril.StripeCheckout

  setup do
    previous_gate = Application.get_env(:mithril, :stripe_booking_checkout_env_gate)
    previous_key = Application.get_env(:mithril, :posthog_project_api_key)
    previous_stripe_secret = Application.get_env(:mithril, :stripe_secret_key)
    previous_webhook_secret = Application.get_env(:mithril, :stripe_webhook_secret)

    on_exit(fn ->
      restore(:stripe_booking_checkout_env_gate, previous_gate)
      restore(:posthog_project_api_key, previous_key)
      restore(:stripe_secret_key, previous_stripe_secret)
      restore(:stripe_webhook_secret, previous_webhook_secret)
    end)

    :ok
  end

  test "booking checkout options fail closed for an unknown booking" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :on)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    Application.put_env(:mithril, :stripe_webhook_secret, "whsec_test")
    user_id = Ecto.UUID.generate()

    assert {:ok, body} =
             MobileFunctions.invoke(user_id, "booking-checkout-options", %{
               "booking_id" => Ecto.UUID.generate(),
               "client_platform" => "ios"
             })

    assert body.paystack_available == true
    assert body.stripe_available == false
    assert body.stripe_unavailable_reason == "booking_unavailable"
  end

  test "global Stripe capability honors the server kill switch" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :off)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    Application.put_env(:mithril, :stripe_webhook_secret, "whsec_test")

    body = StripeCheckout.options(client_platform: "ios")

    assert body.paystack_available == true
    assert body.stripe_available == false
    assert body.stripe_unavailable_reason == "stripe_disabled"
  end

  test "global Stripe capability is available for native clients when fully configured" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :on)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    Application.put_env(:mithril, :stripe_webhook_secret, "whsec_test")

    body = StripeCheckout.options(client_platform: "ios")

    assert body.stripe_available == true
    assert is_nil(body.stripe_unavailable_reason)
  end

  test "global Stripe capability rejects web clients" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :on)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    Application.put_env(:mithril, :stripe_webhook_secret, "whsec_test")

    body = StripeCheckout.options(client_platform: "web")

    assert body.stripe_available == false
    assert body.stripe_unavailable_reason == "web_unsupported"
  end

  test "booking options remain disabled when the release gate has no PostHog key" do
    Application.put_env(:mithril, :stripe_booking_checkout_env_gate, :unset)
    Application.put_env(:mithril, :stripe_secret_key, "sk_test")
    Application.put_env(:mithril, :stripe_webhook_secret, "whsec_test")
    Application.delete_env(:mithril, :posthog_project_api_key)
    user_id = Ecto.UUID.generate()

    assert {:ok, body} = MobileGateway.invoke_function(user_id, "booking-checkout-options", %{})

    assert body.stripe_available == false
    assert body.stripe_unavailable_reason == "booking_unavailable"
  end

  defp restore(key, nil), do: Application.delete_env(:mithril, key)
  defp restore(key, value), do: Application.put_env(:mithril, key, value)
end
