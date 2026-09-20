defmodule Mithril.Paystack do
  @moduledoc false

  @callback initialize(map()) :: {:ok, map()} | {:error, term()}
  @callback verify(String.t()) :: {:ok, map()} | {:error, term()}
  @callback refund(map()) :: {:ok, map()} | {:error, term()}

  def initialize(attrs) when is_map(attrs), do: adapter().initialize(attrs)
  def verify(reference) when is_binary(reference), do: adapter().verify(reference)
  def refund(attrs) when is_map(attrs), do: adapter().refund(attrs)

  def configured? do
    adapter() != Mithril.Paystack.Disabled and adapter().configured?()
  end

  def adapter do
    Application.get_env(:mithril, :paystack_adapter, Mithril.Paystack.Disabled)
  end
end

defmodule Mithril.Paystack.Disabled do
  @moduledoc false
  @behaviour Mithril.Paystack

  @impl true
  def initialize(_attrs), do: {:error, :payment_not_configured}

  @impl true
  def verify(_reference), do: {:error, :payment_not_configured}

  @impl true
  def refund(_attrs), do: {:error, :payment_not_configured}

  def configured?, do: false
end

defmodule Mithril.Paystack.Test do
  @moduledoc false
  @behaviour Mithril.Paystack

  @impl true
  def initialize(attrs) do
    reference = attrs.reference

    record = %{
      authorization_url: "https://checkout.paystack.com/#{reference}",
      access_code: "access_#{reference}",
      reference: reference,
      amount: attrs.amount,
      currency: attrs.currency,
      status: "success",
      split_code: Map.get(attrs, :split_code),
      split: Map.get(attrs, :split)
    }

    put_attempt(reference, record)
    {:ok, Map.take(record, [:authorization_url, :access_code, :reference])}
  end

  @impl true
  def verify(reference) do
    case get_attempt(reference) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl true
  def refund(attrs) do
    case Application.get_env(:mithril, :paystack_test_refund_result, :ok) do
      :ok ->
        {:ok,
         %{
           id: "rf_#{attrs.transaction}",
           status: "pending",
           amount: Map.get(attrs, :amount)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def configured?, do: true

  def put_attempt(reference, record) do
    attempts = Application.get_env(:mithril, :paystack_test_attempts, %{})
    Application.put_env(:mithril, :paystack_test_attempts, Map.put(attempts, reference, record))
  end

  defp get_attempt(reference) do
    Application.get_env(:mithril, :paystack_test_attempts, %{})[reference]
  end
end

defmodule Mithril.Paystack.HTTP do
  @moduledoc false
  @behaviour Mithril.Paystack

  @initialize_url "https://api.paystack.co/transaction/initialize"
  @refund_url "https://api.paystack.co/refund"

  @impl true
  def initialize(attrs) do
    with {:ok, secret} <- secret_key() do
      body =
        %{
          email: attrs.email,
          amount: attrs.amount,
          currency: attrs.currency,
          reference: attrs.reference,
          callback_url: attrs.callback_url,
          metadata: attrs.metadata
        }
        |> Map.merge(Map.take(attrs, [:split_code, :split]))

      case Req.post(@initialize_url, json: body, auth: {:bearer, secret}) do
        {:ok, %{status: status, body: %{"status" => true, "data" => data}}}
        when status in 200..299 ->
          {:ok,
           %{
             authorization_url: data["authorization_url"],
             access_code: data["access_code"],
             reference: data["reference"]
           }}

        {:ok, %{status: status, body: body}} ->
          {:error, {:provider, status, provider_message(body)}}

        {:error, _} ->
          {:error, :provider_unavailable}
      end
    end
  end

  @impl true
  def verify(reference) do
    with {:ok, secret} <- secret_key() do
      url = "https://api.paystack.co/transaction/verify/#{URI.encode(reference)}"

      case Req.get(url, auth: {:bearer, secret}) do
        {:ok, %{status: status, body: %{"status" => true, "data" => data}}}
        when status in 200..299 ->
          {:ok,
           %{
             status: data["status"],
             amount: data["amount"],
             currency: data["currency"],
             reference: data["reference"]
           }}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status, body: body}} ->
          {:error, {:provider, status, provider_message(body)}}

        {:error, _} ->
          {:error, :provider_unavailable}
      end
    end
  end

  @impl true
  def refund(attrs) do
    with {:ok, secret} <- secret_key() do
      body =
        %{transaction: attrs.transaction}
        |> maybe_put(:amount, Map.get(attrs, :amount))
        |> maybe_put(:currency, Map.get(attrs, :currency))
        |> maybe_put(:customer_note, Map.get(attrs, :customer_note))

      case Req.post(@refund_url, json: body, auth: {:bearer, secret}) do
        {:ok, %{status: status, body: %{"status" => true, "data" => data}}}
        when status in 200..299 ->
          {:ok,
           %{
             id: refund_id(data),
             status: data["status"],
             amount: data["amount"]
           }}

        {:ok, %{status: status, body: body}} ->
          {:error, {:provider, status, provider_message(body)}}

        {:error, _} ->
          {:error, :provider_unavailable}
      end
    end
  end

  def configured? do
    match?({:ok, _}, secret_key())
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp refund_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp refund_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp refund_id(_), do: nil

  defp secret_key do
    case Application.get_env(:mithril, :paystack_secret_key) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :payment_not_configured}
    end
  end

  defp provider_message(%{"message" => message}) when is_binary(message), do: message
  defp provider_message(body), do: inspect(body)
end
