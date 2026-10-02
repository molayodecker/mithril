defmodule Mithril.StripeCheckout do
  @moduledoc false

  alias Mithril.Posthog

  @spec options(keyword()) :: map()
  def options(opts \\ []) when is_list(opts) do
    client_platform = Keyword.get(opts, :client_platform)

    {stripe_available, reason} =
      cond do
        not configured?() -> {false, "stripe_disabled"}
        not reconciliation_configured?() -> {false, "stripe_disabled"}
        not enabled_by_release_gate?() -> {false, "stripe_disabled"}
        web_platform?(client_platform) -> {false, "web_unsupported"}
        true -> {true, nil}
      end

    %{
      paystack_available: true,
      stripe_available: stripe_available,
      stripe_unavailable_reason: reason
    }
  end

  @spec checkout_enabled?() :: boolean()
  def checkout_enabled? do
    configured?() and reconciliation_configured?() and enabled_by_release_gate?()
  end

  @spec availability(keyword()) :: %{stripe_available: boolean(), reason: String.t() | nil}
  def availability(opts) when is_list(opts) do
    client_platform = Keyword.get(opts, :client_platform)
    subscription_activatable = Keyword.get(opts, :subscription_activatable, false)
    amount_minor = Keyword.get(opts, :amount_minor, 0)

    {stripe_available, reason} =
      stripe_availability(client_platform, subscription_activatable, amount_minor)

    %{stripe_available: stripe_available, reason: reason}
  end

  defp stripe_availability(client_platform, subscription_activatable, amount_minor) do
    cond do
      not configured?() ->
        {false, "stripe_disabled"}

      not reconciliation_configured?() ->
        {false, "stripe_disabled"}

      not enabled_by_release_gate?() ->
        {false, "stripe_disabled"}

      web_platform?(client_platform) ->
        {false, "web_unsupported"}

      subscription_activatable ->
        {false, "recurring_paystack_only"}

      not positive_amount?(amount_minor) ->
        {false, "no_payable_amount"}

      true ->
        {true, nil}
    end
  end

  defp configured? do
    stripe_secret_key() != ""
  end

  defp reconciliation_configured? do
    case Application.get_env(:mithril, :stripe_webhook_secret) do
      secret when is_binary(secret) -> String.trim(secret) != ""
      _ -> false
    end
  end

  defp enabled_by_release_gate? do
    case Application.get_env(:mithril, :stripe_booking_checkout_env_gate, :unset) do
      :off ->
        false

      :on ->
        true

      :unset ->
        Posthog.fetch_boolean_flag(
          Posthog.booking_stripe_checkout_flag(),
          Posthog.stripe_release_gate_distinct_id(),
          evaluation_runtime: "all"
        )

      _ ->
        false
    end
  end

  defp stripe_secret_key do
    Application.get_env(:mithril, :stripe_secret_key, "")
    |> to_string()
    |> String.trim()
  end

  defp web_platform?(platform) when is_binary(platform) do
    String.downcase(String.trim(platform)) == "web"
  end

  defp web_platform?(_), do: false

  defp positive_amount?(amount) when is_integer(amount), do: amount > 0

  defp positive_amount?(amount) when is_float(amount),
    do: amount > 0 and trunc(amount) == amount

  defp positive_amount?(%Decimal{} = amount), do: Decimal.compare(amount, 0) == :gt

  defp positive_amount?(_), do: false
end
