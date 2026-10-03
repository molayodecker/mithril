defmodule Mithril.MobileFunctions.InitializeStripeBookingPayment do
  @moduledoc false

  alias Mithril.StripeBookingPayments

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    StripeBookingPayments.initialize(user_id, body)
  end
end
