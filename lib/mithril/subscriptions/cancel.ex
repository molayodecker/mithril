defmodule Mithril.Subscriptions.Cancel do
  @moduledoc false

  alias Mithril.MobileFunctions.Paystack
  alias Mithril.Repo

  @type row :: %{
          id: String.t(),
          customer_id: String.t(),
          status: String.t() | nil,
          address: String.t() | nil,
          paystack_subscription_code: String.t() | nil
        }

  @spec cancel_owned(String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def cancel_owned(user_id, subscription_id, cascade_connected) do
    with {:ok, primary} <- load_subscription(subscription_id),
         :ok <- ensure_owner(primary, user_id),
         siblings <- load_siblings(user_id, cascade_connected),
         to_cancel <- subscriptions_to_cancel(primary, siblings, cascade_connected),
         {:ok, result} <- run_cascade(primary, to_cancel) do
      maybe_repair_placeholders(result, Map.get(primary, "id"))
    end
  end

  defp load_subscription(subscription_id) do
    sql = """
    SELECT id, customer_id, status, address, paystack_subscription_code
    FROM public.subscriptions
    WHERE id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [subscription_id]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, row_to_map(columns, row)}
      {:ok, %{rows: []}} -> {:error, {:status, 404, %{error: "Subscription not found"}}}
      {:error, _} -> {:error, {:status, 500, %{error: "Could not load subscription"}}}
    end
  end

  defp ensure_owner(row, user_id) do
    if Map.get(row, "customer_id") == user_id do
      :ok
    else
      {:error, {:status, 403, %{error: "Subscription does not belong to this user"}}}
    end
  end

  defp load_siblings(user_id, true) do
    sql = """
    SELECT id, customer_id, status, address, paystack_subscription_code
    FROM public.subscriptions
    WHERE customer_id = $1::uuid AND status IN ('active', 'pending')
    """

    case Repo.query(sql, [user_id]) do
      {:ok, %{columns: columns, rows: rows}} ->
        Enum.map(rows, &row_to_map(columns, &1))

      _ ->
        []
    end
  end

  defp load_siblings(_user_id, false), do: []

  defp subscriptions_to_cancel(primary, siblings, cascade_connected) do
    connected = select_connected(primary, siblings)
    primary_needs? = cancellable?(Map.get(primary, "status"))

    cond do
      not cascade_connected -> if primary_needs?, do: [primary], else: []
      primary_needs? -> [primary | connected]
      true -> connected
    end
  end

  defp select_connected(primary, siblings) do
    primary_address = normalize_address(Map.get(primary, "address"))

    if primary_address == "" do
      []
    else
      primary_id = Map.get(primary, "id")

      Enum.filter(siblings, fn sibling ->
        sibling_id = Map.get(sibling, "id")

        sibling_id != primary_id and
          Map.get(sibling, "customer_id") == Map.get(primary, "customer_id") and
          cancellable?(Map.get(sibling, "status")) and
          normalize_address(Map.get(sibling, "address")) == primary_address
      end)
    end
  end

  defp run_cascade(primary, []),
    do:
      {:ok,
       %{outcome: :already_cancelled, cancelled_ids: [Map.get(primary, "id")], cascaded_ids: []}}

  defp run_cascade(primary, to_cancel) do
    needs_paystack =
      Enum.any?(to_cancel, fn row ->
        code = Map.get(row, "paystack_subscription_code") |> to_string() |> String.trim()
        code != ""
      end)

    with {:ok, secret} <- maybe_paystack_secret(needs_paystack) do
      {cancelled_ids, errors} =
        Enum.reduce(to_cancel, {[], nil}, fn row, {ids, _error} ->
          case cancel_one(row, secret) do
            :ok -> {[Map.get(row, "id") | ids], nil}
            {:error, message} -> {ids, message}
          end
        end)

      cancelled_ids = Enum.reverse(cancelled_ids)
      primary_id = Map.get(primary, "id")
      cascaded_ids = Enum.reject(cancelled_ids, &(&1 == primary_id))

      if errors do
        remaining_ids = Enum.map(to_cancel, &Map.get(&1, "id")) -- cancelled_ids

        {:error,
         {:status, 502,
          %{
            error: errors,
            cancelled_ids: cancelled_ids,
            remaining_ids: remaining_ids,
            cascaded_ids: cascaded_ids
          }}}
      else
        {:ok, %{outcome: :complete, cancelled_ids: cancelled_ids, cascaded_ids: cascaded_ids}}
      end
    end
  end

  defp maybe_repair_placeholders(%{outcome: :already_cancelled}, subscription_id) do
    case cancel_locally(subscription_id) do
      :ok ->
        {:ok,
         %{
           success: true,
           message: "Subscription already cancelled",
           cancelled_ids: [subscription_id],
           cascaded_ids: []
         }}

      {:error, message} ->
        {:error,
         {:status, 502, %{error: message, cancelled_ids: [subscription_id], cascaded_ids: []}}}
    end
  end

  defp maybe_repair_placeholders(%{outcome: :complete} = result, _subscription_id) do
    message =
      if result.cascaded_ids != [] do
        count = length(result.cascaded_ids)

        "Subscription cancelled (including #{count} connected plan#{if count == 1, do: "", else: "s"} at the same address)"
      else
        "Subscription cancelled"
      end

    {:ok,
     %{
       success: true,
       message: message,
       cancelled_ids: result.cancelled_ids,
       cascaded_ids: result.cascaded_ids
     }}
  end

  defp cancel_one(row, secret) do
    code = Map.get(row, "paystack_subscription_code") |> to_string() |> String.trim()

    with :ok <- maybe_disable_paystack(code, secret),
         :ok <- cancel_locally(Map.get(row, "id")) do
      :ok
    end
  end

  defp maybe_disable_paystack("", _secret), do: :ok

  defp maybe_disable_paystack(code, secret) do
    case Paystack.get_json("/subscription/#{URI.encode(code)}", secret) do
      {:ok, data} ->
        email_token = Map.get(data, "email_token")

        if is_binary(email_token) and String.trim(email_token) != "" do
          case Paystack.post_json(
                 "/subscription/disable",
                 %{"code" => code, "token" => email_token},
                 secret
               ) do
            {:ok, _data} -> :ok
            {:error, {:status, _status, message}} -> {:error, message}
          end
        else
          {:error, "Missing Paystack email token; cannot disable remote subscription safely"}
        end

      {:error, {:status, _status, message}} ->
        {:error, to_string(message)}
    end
  end

  defp maybe_paystack_secret(true) do
    case Paystack.secret_key() do
      {:ok, secret} ->
        {:ok, secret}

      {:error, :payment_not_configured} ->
        {:error, {:status, 500, %{error: "Payment is not configured"}}}
    end
  end

  defp maybe_paystack_secret(false), do: {:ok, nil}

  defp cancel_locally(subscription_id) do
    case Repo.query("SELECT public.cancel_subscription_with_unpaid_placeholders($1::uuid)", [
           subscription_id
         ]) do
      {:ok, %{rows: [[payload]]}} when is_map(payload) ->
        action = Map.get(payload, "action") |> to_string() |> String.downcase()

        if action == "error" do
          {:error,
           Map.get(payload, "error", "Failed to cancel subscription locally") |> to_string()}
        else
          :ok
        end

      {:ok, %{rows: [[payload]]}} ->
        _ = payload
        :ok

      {:error, _} ->
        {:error, "Could not cancel subscription"}
    end
  end

  defp cancellable?(status) do
    normalized = status |> to_string() |> String.trim() |> String.downcase()
    normalized in ["active", "pending"]
  end

  defp normalize_address(address) do
    address
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp row_to_map(columns, row), do: Map.new(Enum.zip(columns, row))
end
