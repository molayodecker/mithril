defmodule Mithril.MobileFunctions.BookingCheckoutOptions do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Posthog
  alias Mithril.Repo

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @stripe_flag "booking_stripe_checkout_v1"
  @stripe_distinct_id "instaclean-stripe-checkout-release-gate"

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_map(body) do
    booking_id =
      body
      |> Map.get("booking_id", Map.get(body, :booking_id, ""))
      |> to_string()
      |> String.trim()

    cond do
      not Regex.match?(@uuid_regex, booking_id) ->
        {:error, {:status, 400, %{error: "booking_id must be a UUID"}}}

      true ->
        case owned_booking?(user_id, booking_id) do
          :ok -> {:ok, options()}
          :missing -> {:error, {:status, 404, %{error: "Booking not found"}}}
          :error -> {:error, {:status, 500, %{error: "Could not load payment options"}}}
        end
    end
  end

  defp owned_booking?(user_id, booking_id) do
    case Repo.query(
           """
           SELECT 1
           FROM public.bookings
           WHERE id = $1::uuid AND customer_id = $2::uuid
           LIMIT 1
           """,
           [DbUuid.dump!(booking_id), DbUuid.dump!(user_id)]
         ) do
      {:ok, %{rows: [_ | _]}} -> :ok
      {:ok, %{rows: []}} -> :missing
      {:error, _error} -> :error
    end
  end

  defp options do
    paystack_available = paystack_configured?()
    stripe_kill_switch = stripe_checkout_enabled?()

    stripe_flag =
      if stripe_kill_switch do
        Posthog.fetch_boolean_flag(@stripe_flag, @stripe_distinct_id)
      else
        false
      end

    stripe_available = stripe_kill_switch and stripe_flag

    %{
      paystack_available: paystack_available,
      stripe_available: stripe_available,
      stripe_unavailable_reason:
        stripe_unavailable_reason(stripe_available, stripe_kill_switch, stripe_flag)
    }
  end

  defp stripe_unavailable_reason(true, _kill_switch, _flag), do: nil
  defp stripe_unavailable_reason(false, false, _flag), do: "kill_switch"
  defp stripe_unavailable_reason(false, true, false), do: "flag_disabled"

  defp paystack_configured? do
    case Application.get_env(:mithril, :paystack_secret_key) do
      secret when is_binary(secret) and secret != "" -> true
      _ -> false
    end
  end

  defp stripe_checkout_enabled? do
    Application.get_env(:mithril, :stripe_booking_checkout_enabled) == true
  end
end
