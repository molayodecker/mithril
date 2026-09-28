defmodule Mithril.Subscriptions.ManagedRenewal do
  @moduledoc false

  @non_final ~w(pending ongoing processing queued)

  @spec reference(String.t(), String.t()) :: String.t()
  def reference(subscription_id, occurrence_date) do
    day = occurrence_date |> String.trim() |> String.replace("-", "")
    "MGR-#{String.trim(subscription_id)}-#{day}"
  end

  @spec should_initiate_charge?(atom(), atom()) :: boolean()
  def should_initiate_charge?(attempt_status, verify_kind) do
    attempt_status not in [:charged, :paid, :paused] and verify_kind == :not_found
  end

  @spec interpret_paystack(integer(), term(), String.t()) :: term()
  def interpret_paystack(http_status, body, requested_reference) do
    cond do
      http_status == 404 ->
        :not_found

      not is_map(body) ->
        {:failed, "paystack_empty_body (#{http_status})", requested_reference}

      not_found_message?(Map.get(body, "message")) and http_status == 404 ->
        :not_found

      true ->
        case Map.get(body, "data") do
          data when is_map(data) ->
            interpret_paystack_data(http_status, body, data, requested_reference)

          _ ->
            if Map.get(body, "status") == false and not_found_message?(Map.get(body, "message")) do
              :not_found
            else
              {:failed, "paystack_missing_data (#{http_status})", requested_reference}
            end
        end
    end
  end

  @spec run(map()) :: {:ok, atom(), term()} | {:error, term()}
  def run(deps) when is_map(deps) do
    attempt = deps.claim_attempt.()

    if attempt.status == :paid do
      {:ok, :skipped, %{}}
    else
      verify = deps.verify_reference.(attempt.paystack_reference)
      verify_kind = outcome_kind(verify)

      txn =
        cond do
          should_initiate_charge?(attempt.status, verify_kind) ->
            deps.charge_authorization.(%{
              authorization_code: deps.authorization_code,
              email: deps.email,
              amount_minor: deps.amount_minor,
              currency: deps.currency,
              reference: attempt.paystack_reference
            })

          attempt.status == :charged and verify_kind == :not_found ->
            :charged_verify_missing

          true ->
            verify
        end

      case txn do
        :charged_verify_missing ->
          deps.update_attempt.(%{status: :failed, last_error: "charged_but_verify_missing"})
          {:ok, :failed, %{error: "charged_but_verify_missing"}}

        {:paused, _reference, _authorization_url} ->
          deps.update_attempt.(%{
            status: :paused,
            paystack_transaction_status: "paused",
            last_error: nil
          })

          {:ok, :waiting, %{reason: "paused"}}

        {:pending, _reference, transaction_status} ->
          deps.update_attempt.(%{
            status: :paused,
            paystack_transaction_status: transaction_status,
            last_error: nil
          })

          {:ok, :waiting, %{reason: transaction_status}}

        :not_found ->
          deps.update_attempt.(%{status: :failed, last_error: "paystack_reference_not_found"})
          {:ok, :failed, %{error: "paystack_reference_not_found"}}

        {:failed, error, _reference} ->
          deps.update_attempt.(%{
            status: :failed,
            last_error: error,
            paystack_transaction_status: "failed"
          })

          {:ok, :failed, %{error: error}}

        {:success, reference} ->
          finalize_after_success(reference, attempt, deps)
      end
    end
  end

  defp finalize_after_success(reference, _attempt, deps) do
    deps.update_attempt.(%{
      status: :charged,
      paystack_transaction_status: "success",
      last_error: nil
    })

    booking =
      case deps.find_booking.() do
        nil ->
          case deps.insert_booking.(reference) do
            {:ok, %{id: booking_id}} ->
              %{id: booking_id, payment_status: "pending"}

            {:error, message} ->
              deps.update_attempt.(%{status: :charged, last_error: message})
              nil
          end

        existing ->
          existing
      end

    if is_nil(booking) do
      {:ok, :failed, %{error: "booking_insert_failed_after_charge"}}
    else
      deps.update_attempt.(%{booking_id: booking.id})

      paid_ok =
        if booking.payment_status == "paid" do
          :ok
        else
          deps.mark_booking_paid.(booking.id)
        end

      case paid_ok do
        :ok ->
          case deps.advance_recurrence.() do
            :ok ->
              deps.update_attempt.(%{status: :paid, booking_id: booking.id, last_error: nil})
              {:ok, :paid, %{}}

            {:error, error} ->
              deps.update_attempt.(%{status: :charged, booking_id: booking.id, last_error: error})
              {:ok, :failed, %{error: error}}
          end

        {:error, error} ->
          deps.update_attempt.(%{status: :charged, booking_id: booking.id, last_error: error})
          {:ok, :failed, %{error: error}}
      end
    end
  end

  defp interpret_paystack_data(http_status, body, data, requested_reference) do
    reference = read_string(Map.get(data, "reference")) || requested_reference
    txn_status = read_string(Map.get(data, "status")) |> String.downcase()
    paused = Map.get(data, "paused") == true
    authorization_url = read_string(Map.get(data, "authorization_url"))

    cond do
      paused ->
        {:paused, reference, authorization_url}

      txn_status in @non_final ->
        {:pending, reference, txn_status}

      api_ok?(http_status, body) and txn_status == "success" ->
        {:success, reference}

      true ->
        error =
          read_string(Map.get(body, "message")) ||
            if(txn_status != "",
              do: "paystack_txn_#{txn_status}",
              else: "paystack_charge_failed (#{http_status})"
            )

        {:failed, error, reference}
    end
  end

  defp outcome_kind(:not_found), do: :not_found
  defp outcome_kind({:success, _}), do: :success
  defp outcome_kind({:paused, _, _}), do: :paused
  defp outcome_kind({:pending, _, _}), do: :pending
  defp outcome_kind({:failed, _, _}), do: :failed

  defp api_ok?(status, body) when is_integer(status) and is_map(body) do
    status >= 200 and status < 300 and Map.get(body, "status") == true
  end

  defp not_found_message?(message) when is_binary(message) do
    lower = String.downcase(message)

    String.contains?(lower, "not found") or
      String.contains?(lower, "did not match any transaction")
  end

  defp not_found_message?(_), do: false

  defp read_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp read_string(_), do: nil
end
