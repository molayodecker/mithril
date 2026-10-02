defmodule Mithril.MobileFunctions.BookingCheckoutOptions do
  @moduledoc false

  alias Mithril.StripeCheckout

  @spec call(String.t(), map()) :: {:ok, map()}
  def call(_user_id, _body) do
    {:ok, StripeCheckout.options()}
  end
end
