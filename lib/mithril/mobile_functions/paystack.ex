defmodule Mithril.MobileFunctions.Paystack do
  @moduledoc false

  alias Mithril.MobileFunctions.PaystackPayout
  alias Mithril.MobileGateway
  alias Mithril.Repo

  @allowed_currencies ~w(GHS NGN USD KES ZAR)

  @spec fetch_banks(map()) :: {:ok, map()} | {:error, term()}
  def fetch_banks(body) when is_map(body) do
    with {:ok, secret} <- secret_key(),
         currency <- normalize_currency(body),
         {:ok, banks} <- paystack_get("/bank?currency=#{URI.encode(currency)}", secret) do
      active_banks =
        Enum.filter(banks, fn bank ->
          Map.get(bank, "active") == true and Map.get(bank, "is_deleted") != true
        end)

      {:ok, %{ok: true, data: active_banks}}
    else
      {:error, :payment_not_configured} ->
        {:error, {:status, 500, %{ok: false, error: "Paystack secret not configured"}}}

      {:error, {:status, status, message}} ->
        {:error, {:status, status, %{ok: false, error: message}}}
    end
  end

  @spec create_transfer_recipient(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_transfer_recipient(user_id, body) when is_map(body) and is_binary(user_id) do
    PaystackPayout.create_recipient(user_id, body)
  end

  @spec initiate_transfer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def initiate_transfer(user_id, body) when is_map(body) and is_binary(user_id) do
    PaystackPayout.initiate_transfer(user_id, body)
  end

  @spec resolve_bank_account(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_bank_account(user_id, body) when is_map(body) and is_binary(user_id) do
    account_number =
      body
      |> Map.get("account_number", "")
      |> to_string()
      |> String.trim()

    bank_code =
      body
      |> Map.get("bank_code", "")
      |> to_string()
      |> String.trim()

    cond do
      not Regex.match?(~r/^\d{6,20}$/, account_number) ->
        {:error, {:status, 400, %{ok: false, error: "Invalid account number"}}}

      not Regex.match?(~r/^[A-Z0-9_-]{1,32}$/i, bank_code) ->
        {:error, {:status, 400, %{ok: false, error: "Invalid bank code"}}}

      true ->
        with :ok <- rate_limit_resolve(user_id),
             {:ok, secret} <- secret_key(),
             query <-
               URI.encode_query(%{
                 "account_number" => account_number,
                 "bank_code" => bank_code
               }),
             {:ok, data} <- paystack_get("/bank/resolve?#{query}", secret) do
          {:ok,
           %{
             ok: true,
             data: %{
               account_number: Map.get(data, "account_number", account_number),
               account_name: Map.get(data, "account_name"),
               bank_id: Map.get(data, "bank_id")
             }
           }}
        else
          {:error, :rate_limited} ->
            {:error,
             {:status, 429, %{ok: false, error: "Too many lookups. Try again in a moment."}}}

          {:error, :payment_not_configured} ->
            {:error, {:status, 500, %{ok: false, error: "Server misconfigured"}}}

          {:error, {:status, status, message}} ->
            http_status = if status >= 500, do: 502, else: 400
            {:error, {:status, http_status, %{ok: false, error: message}}}
        end
    end
  end

  defp normalize_currency(body) do
    raw =
      body
      |> Map.get("currency", "GHS")
      |> to_string()
      |> String.trim()

    currency = String.upcase(if raw == "", do: "GHS", else: raw)

    if currency in @allowed_currencies, do: currency, else: "GHS"
  end

  def secret_key do
    case Application.get_env(:mithril, :paystack_secret_key) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :payment_not_configured}
    end
  end

  def get_json(path, secret) when is_binary(path) and is_binary(secret), do: paystack_get(path, secret)

  def post_json(path, body, secret) when is_binary(path) and is_map(body) and is_binary(secret) do
    url = "https://api.paystack.co#{path}"

    case Req.post(url, json: body, auth: {:bearer, secret}) do
      {:ok, %{status: status, body: %{"status" => true, "data" => data}}}
      when status in 200..299 ->
        {:ok, data}

      {:ok, %{status: status, body: response_body}} ->
        message = provider_message(response_body)
        status_code = if status >= 500, do: 502, else: 400
        {:error, {:status, status_code, message}}

      {:error, _} ->
        {:error, {:status, 502, "Paystack unavailable"}}
    end
  end

  defp paystack_get(path, secret) do
    url = "https://api.paystack.co#{path}"

    case Req.get(url, auth: {:bearer, secret}) do
      {:ok, %{status: status, body: %{"status" => true, "data" => data}}}
      when status in 200..299 ->
        {:ok, data}

      {:ok, %{status: status, body: body}} ->
        message = provider_message(body)
        status_code = if status >= 500, do: 502, else: 400
        {:error, {:status, status_code, message}}

      {:error, _} ->
        {:error, {:status, 502, "Paystack unavailable"}}
    end
  end

  defp provider_message(%{"message" => message}) when is_binary(message), do: message
  defp provider_message(_), do: "Paystack request failed"

  defp rate_limit_resolve(user_id) do
    case MobileGateway.with_user_transaction(user_id, fn ->
           case Repo.query(
                  "SELECT public.record_lookup_attempt($1, $2, $3, $4) AS blocked",
                  ["paystack_bank_resolve", user_id, 20, 60]
                ) do
             {:ok, %{rows: [[true]]}} ->
               {:error, :rate_limited}

             {:ok, %{rows: [[false]]}} ->
               {:ok, :ok}

             _ ->
               {:ok, :ok}
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
      _ -> :ok
    end
  end
end
