defmodule Mithril.MobileFunctions.BookingCheckoutOptions do
  @moduledoc false

  alias Mithril.StripeBookingPayments

  @spec call(String.t(), map()) :: {:ok, map()}
  def call(user_id, body) do
    StripeBookingPayments.options(user_id, body)
  end
end
