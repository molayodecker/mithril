defmodule Mithril.MobileFunctions.StripeVerifyPaymentIntent do
  @moduledoc false

  alias Mithril.StripeBookingPayments

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    StripeBookingPayments.verify_payment_intent(user_id, body)
  end
end
