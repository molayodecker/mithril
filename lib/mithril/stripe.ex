defmodule Mithril.Stripe do
  @moduledoc false

  @callback create_payment_intent(map()) :: {:ok, map()} | {:error, term()}
  @callback fetch_payment_intent(String.t()) :: {:ok, map()} | {:error, term()}
  @callback cancel_payment_intent(String.t()) :: :ok | {:error, term()}

  def create_payment_intent(attrs) when is_map(attrs), do: adapter().create_payment_intent(attrs)
  def fetch_payment_intent(id) when is_binary(id), do: adapter().fetch_payment_intent(id)
  def cancel_payment_intent(id) when is_binary(id), do: adapter().cancel_payment_intent(id)

  def configured? do
    adapter() != Mithril.Stripe.Disabled and adapter().configured?()
  end

  def adapter do
    Application.get_env(:mithril, :stripe_adapter, Mithril.Stripe.Disabled)
  end
end

defmodule Mithril.Stripe.Disabled do
  @moduledoc false
  @behaviour Mithril.Stripe

  @impl true
  def create_payment_intent(_attrs), do: {:error, :payment_not_configured}

  @impl true
  def fetch_payment_intent(_id), do: {:error, :payment_not_configured}

  @impl true
  def cancel_payment_intent(_id), do: {:error, :payment_not_configured}

  def configured?, do: false
end

defmodule Mithril.Stripe.Test do
  @moduledoc false
  @behaviour Mithril.Stripe

  @impl true
  def create_payment_intent(attrs) do
    reference = Map.fetch!(attrs, :reference)

    form_params = Map.get(attrs, :form_params, %{})

    record = %{
      id: "pi_test_#{reference}",
      client_secret: "pi_test_secret_#{reference}",
      amount: Map.get(form_params, :amount) || Map.get(form_params, "amount"),
      currency: Map.get(form_params, :currency) || Map.get(form_params, "currency"),
      status: "requires_payment_method"
    }

    put_intent(record.id, record)
    {:ok, record}
  end

  @impl true
  def fetch_payment_intent(id) do
    case get_intent(id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl true
  def cancel_payment_intent(_id), do: :ok

  def configured?, do: true

  defp put_intent(id, record) do
    intents = Application.get_env(:mithril, :stripe_test_intents, %{})
    Application.put_env(:mithril, :stripe_test_intents, Map.put(intents, id, record))
  end

  defp get_intent(id) do
    Application.get_env(:mithril, :stripe_test_intents, %{})[id]
  end
end

defmodule Mithril.Stripe.HTTP do
  @moduledoc false
  @behaviour Mithril.Stripe

  @api_url "https://api.stripe.com/v1"

  @impl true
  def create_payment_intent(attrs) do
    with {:ok, secret} <- secret_key() do
      body = encode_form(attrs[:form_params] || %{})
      idempotency_key = attrs[:reference]

      case Req.post("#{@api_url}/payment_intents",
             auth: {:bearer, secret},
             body: body,
             headers: form_headers(idempotency_key),
             receive_timeout: 15_000
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:ok,
           %{
             id: body["id"],
             client_secret: body["client_secret"],
             amount: body["amount"],
             currency: body["currency"],
             status: body["status"]
           }}

        {:ok, %{status: status, body: body}} ->
          {:error, {:provider, status, stripe_message(body)}}

        {:error, _} ->
          {:error, :provider_unavailable}
      end
    end
  end

  @impl true
  def fetch_payment_intent(payment_intent_id) do
    with {:ok, secret} <- secret_key() do
      url = "#{@api_url}/payment_intents/#{URI.encode(payment_intent_id)}"

      case Req.get(url, auth: {:bearer, secret}, receive_timeout: 8_000) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:ok,
           %{
             id: body["id"],
             client_secret: body["client_secret"],
             amount: body["amount"],
             currency: body["currency"]
           }}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status, body: body}} ->
          {:error, {:provider, status, stripe_message(body)}}

        {:error, _} ->
          {:error, :provider_unavailable}
      end
    end
  end

  @impl true
  def cancel_payment_intent(payment_intent_id) do
    with {:ok, secret} <- secret_key() do
      url = "#{@api_url}/payment_intents/#{URI.encode(payment_intent_id)}/cancel"

      case Req.post(url, auth: {:bearer, secret}, receive_timeout: 8_000) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _ -> {:error, :provider_unavailable}
      end
    end
  end

  def configured? do
    match?({:ok, _}, secret_key())
  end

  defp encode_form(params) when is_map(params) do
    params
    |> Enum.flat_map(fn entry -> flatten_form(entry, "") end)
    |> URI.encode_query()
  end

  defp flatten_form({key, value}, prefix) when is_map(value) do
    Enum.flat_map(value, fn {nested_key, nested_value} ->
      flatten_form({nested_key, nested_value}, "#{prefix}[#{key}]")
    end)
  end

  defp flatten_form({key, value}, prefix) do
    encoded_key = if prefix == "", do: to_string(key), else: "#{prefix}[#{key}]"
    [{encoded_key, to_string(value)}]
  end

  defp form_headers(idempotency_key) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    if is_binary(idempotency_key) and idempotency_key != "" do
      [{"idempotency-key", idempotency_key} | headers]
    else
      headers
    end
  end

  defp stripe_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp stripe_message(_), do: "Stripe request failed"

  defp secret_key do
    case Application.get_env(:mithril, :stripe_secret_key) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :payment_not_configured}
    end
  end
end
