defmodule Mithril.Paystack.Transactions do
  @moduledoc false

  alias Mithril.Subscriptions.ManagedRenewal

  @charge_url "https://api.paystack.co/transaction/charge_authorization"

  @spec verify_raw(String.t()) :: term()
  def verify_raw(reference) when is_binary(reference) do
    with {:ok, secret} <- secret_key() do
      url = "https://api.paystack.co/transaction/verify/#{URI.encode(reference)}"

      case Req.get(url, auth: {:bearer, secret}) do
        {:ok, %{status: status, body: body}} ->
          ManagedRenewal.interpret_paystack(status, body, reference)

        {:error, _} ->
          {:failed, "paystack_unavailable", reference}
      end
    else
      {:error, :payment_not_configured} ->
        {:failed, "payment_not_configured", reference}
    end
  end

  @spec charge_authorization(map()) :: term()
  def charge_authorization(params) when is_map(params) do
    with {:ok, secret} <- secret_key() do
      body = %{
        authorization_code: params.authorization_code,
        email: params.email,
        amount: params.amount_minor,
        currency: params.currency,
        reference: params.reference
      }

      case Req.post(@charge_url, json: body, auth: {:bearer, secret}) do
        {:ok, %{status: status, body: body}} ->
          ManagedRenewal.interpret_paystack(status, body, params.reference)

        {:error, _} ->
          {:failed, "paystack_unavailable", params.reference}
      end
    else
      {:error, :payment_not_configured} ->
        {:failed, "payment_not_configured", params.reference}
    end
  end

  defp secret_key do
    case Application.get_env(:mithril, :paystack_secret_key) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :payment_not_configured}
    end
  end
end
