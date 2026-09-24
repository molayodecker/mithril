defmodule Mithril.MobileFunctions.UberTransportationReleaseGate do
  @moduledoc false

  alias Mithril.Posthog
  alias Mithril.Uber.TransportationReleaseGate

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(_user_id, _body) do
    enabled =
      Posthog.fetch_boolean_flag(
        Posthog.booking_uber_transportation_flag(),
        Posthog.uber_release_gate_distinct_id()
      )

    case TransportationReleaseGate.sync(enabled) do
      :ok -> {:ok, %{enabled: enabled}}
      {:error, error} ->
        {:error,
         {:status, 503,
          %{
            error: "Could not synchronize transportation kill switch",
            code: "release_gate_sync_failed",
            enabled: enabled,
            details: inspect(error)
          }}}
    end
  end
end

defmodule Mithril.MobileFunctions.FetchOtpDeliveryToken do
  @moduledoc false

  alias Mithril.OtpDelivery

  def call(_user_id, body) when is_map(body) do
    phone = body |> Map.get("phone", "") |> to_string()

    case OtpDelivery.fetch_token_for_phone(phone) do
      {:ok, payload} -> {:ok, payload}
      {:error, {:status, status, body}} -> {:error, {:status, status, body}}
    end
  end
end

defmodule Mithril.MobileFunctions.ResendOtpViaChannel do
  @moduledoc false

  alias Mithril.OtpDelivery

  def call(_user_id, body) when is_map(body) do
    delivery_token = body |> Map.get("delivery_token", "") |> to_string()
    channel = body |> Map.get("channel", "") |> to_string()

    case OtpDelivery.resend_via_channel(delivery_token, channel) do
      {:ok, payload} -> {:ok, payload}
      {:error, {:status, status, body}} -> {:error, {:status, status, body}}
    end
  end
end

defmodule Mithril.MobileFunctions.CancelSubscription do
  @moduledoc false

  alias Mithril.Subscriptions.Cancel

  def call(user_id, body) when is_map(body) do
    subscription_id =
      body
      |> Map.get("subscription_id", Map.get(body, "subscriptionId", ""))
      |> to_string()
      |> String.trim()

    cascade =
      Map.get(body, "cascade_connected") == true or Map.get(body, "cascadeConnected") == true

    if subscription_id == "" do
      {:error, {:status, 400, %{error: "Missing or invalid subscription_id"}}}
    else
      Cancel.cancel_owned(user_id, subscription_id, cascade)
    end
  end
end
