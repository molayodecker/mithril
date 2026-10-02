defmodule Mithril.MobileFunctions.BookingCheckoutOptions do
  @moduledoc false

  alias Mithril.StripeCheckout

  @spec call(String.t(), map()) :: {:ok, map()}
  def call(_user_id, body) do
    client_platform =
      case body["client_platform"] || body["clientPlatform"] do
        value when is_binary(value) -> String.trim(value)
        _ -> nil
      end

    {:ok, StripeCheckout.options(client_platform: client_platform)}
  end
end
