defmodule Mithril.Paystack.Webhook do
  @moduledoc false

  require Logger

  alias Mithril.DirectCancellation
  alias Mithril.Repo

  @refund_events ~w(
    refund.pending
    refund.processing
    refund.processed
    refund.failed
    refund.needs-attention
  )

  @type error ::
          :unauthorized
          | :not_configured
          | :invalid_json
          | :invalid_payload
          | :amount_mismatch
          | :payment_incomplete
          | :payment_reference_mismatch
          | :payment_not_payable
          | :database_unavailable

  @spec handle(binary(), String.t() | nil) :: {:ok, map()} | {:error, error()}
  def handle(raw_body, signature) when is_binary(raw_body) do
    request_id = Ecto.UUID.generate()

    with {:ok, secret} <- webhook_secret(),
         :ok <- verify_signature(secret, raw_body, signature),
         {:ok, payload} <- decode_payload(raw_body),
         {:ok, event} <- parse_event(payload),
         {:ok, result} <- dispatch(event) do
      {:ok, Map.merge(%{request_id: request_id, event: event.type}, result)}
    else
      {:error, :not_configured} = error ->
        Logger.error("paystack webhook missing PAYSTACK_SECRET_KEY request_id=#{request_id}")
        error

      {:error, :unauthorized} = error ->
        Logger.warning("paystack webhook invalid signature request_id=#{request_id}")
        error

      {:error, :invalid_json} = error ->
        Logger.warning("paystack webhook invalid JSON request_id=#{request_id}")
        error

      {:error, :invalid_payload} = error ->
        Logger.warning("paystack webhook missing event request_id=#{request_id}")
        error

      {:error, reason} = error
      when reason in [
             :amount_mismatch,
             :payment_incomplete,
             :payment_reference_mismatch,
             :payment_not_payable
           ] ->
        Logger.warning(
          "paystack webhook rejected request_id=#{request_id} error=#{inspect(reason)}"
        )

        error

      {:error, error} ->
        Logger.error(
          "paystack webhook persist failed request_id=#{request_id} error=#{inspect(error)}"
        )

        {:error, :database_unavailable}
    end
  end

  def handle(_raw_body, _signature), do: {:error, :invalid_payload}

  def verify_signature(secret, raw_body, signature)
      when is_binary(secret) and is_binary(raw_body) and is_binary(signature) do
    expected =
      :hmac
      |> :crypto.mac(:sha512, secret, raw_body)
      |> Base.encode16(case: :lower)

    digest = signature |> String.trim() |> String.downcase()

    if byte_size(digest) == byte_size(expected) and Plug.Crypto.secure_compare(digest, expected) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def verify_signature(_secret, _raw_body, _signature), do: {:error, :unauthorized}

  defp dispatch(%{type: "charge.success"} = event), do: settle_charge(event)
  defp dispatch(%{type: "charge.failed"} = event), do: fail_charge(event)
  defp dispatch(%{type: "transfer.success"} = event), do: settle_transfer(event, "success")
  defp dispatch(%{type: "transfer.failed"} = event), do: settle_transfer(event, "failed")
  defp dispatch(%{type: "transfer.reversed"} = event), do: settle_transfer(event, "reversed")

  defp dispatch(%{type: type} = event) when type in @refund_events do
    settle_refund(event)
  end

  defp dispatch(%{type: type}) do
    {:ok, %{ignored: true, reason: "unhandled_event", event: type}}
  end

  defp settle_charge(event) do
    reference = event.reference

    if is_nil(reference) do
      {:ok, %{ignored: true, reason: "missing_reference"}}
    else
      Repo.transaction(fn ->
        case lock_attempt(reference) do
          nil ->
            Logger.info("paystack webhook unknown charge reference=#{reference}")
            %{ignored: true, reason: "unknown_reference", reference: reference}

          attempt ->
            apply_charge(attempt, event)
        end
      end)
      |> normalize_transaction()
    end
  end

  defp apply_charge(attempt, event) do
    cond do
      paid?(attempt.payment_status) and attempt.booking_reference == attempt.reference ->
        %{already_paid: true, reference: attempt.reference, booking_id: attempt.booking_id}

      attempt.booking_status == "cancelled" and not paid?(attempt.payment_status) ->
        Repo.rollback(:payment_not_payable)

      event.status not in [nil, "success"] ->
        Repo.rollback(:payment_incomplete)

      event.amount_minor != attempt.amount_minor ->
        Repo.rollback(:amount_mismatch)

      event.currency != attempt.currency ->
        Repo.rollback(:amount_mismatch)

      attempt.booking_reference != attempt.reference ->
        Repo.rollback(:payment_reference_mismatch)

      true ->
        mark_paid!(attempt)
        %{settled: true, reference: attempt.reference, booking_id: attempt.booking_id}
    end
  end

  defp mark_paid!(attempt) do
    with {:ok, %{num_rows: rows}} when rows > 0 <-
           Repo.query(
             """
             UPDATE public.payment_attempts
             SET status = 'paid',
                 paid_at = coalesce(paid_at, now()),
                 updated_at = now()
             WHERE id = $1
             """,
             [attempt.attempt_id]
           ),
         {:ok, %{num_rows: booking_rows}} when booking_rows > 0 <-
           Repo.query(
             """
             UPDATE public.bookings
             SET payment_status = 'paid',
                 payment_method = 'paystack',
                 updated_at = now()
             WHERE id = $1
               AND reference = $2
             """,
             [attempt.booking_uuid, attempt.reference]
           ) do
      :ok
    else
      {:ok, %{num_rows: 0}} -> Repo.rollback(:payment_reference_mismatch)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp fail_charge(event) do
    reference = event.reference

    if is_nil(reference) do
      {:ok, %{ignored: true, reason: "missing_reference"}}
    else
      case Repo.query(
             """
             UPDATE public.payment_attempts
             SET status = 'failed',
                 failure_reason = coalesce($2, failure_reason),
                 failed_at = coalesce(failed_at, now()),
                 updated_at = now()
             WHERE reference = $1
               AND status IN ('initializing', 'ready')
             RETURNING id
             """,
             [reference, event.gateway_response]
           ) do
        {:ok, %{num_rows: 0}} ->
          {:ok, %{ignored: true, reason: "unknown_or_terminal_reference", reference: reference}}

        {:ok, _} ->
          {:ok, %{failed: true, reference: reference}}

        {:error, error} ->
          Logger.error("paystack webhook charge.failed persist error=#{inspect(error)}")
          {:error, :database_unavailable}
      end
    end
  end

  defp settle_transfer(event, desired_status) do
    reference = event.reference

    if is_nil(reference) do
      {:ok, %{ignored: true, reason: "missing_reference"}}
    else
      Repo.transaction(fn ->
        case lock_transfer(reference) do
          nil ->
            Logger.info("paystack webhook unknown transfer reference=#{reference}")
            %{ignored: true, reason: "unknown_transfer_reference", reference: reference}

          payout ->
            apply_transfer(payout, event, desired_status)
        end
      end)
      |> normalize_transaction()
    end
  end

  defp apply_transfer(payout, event, desired_status) do
    cond do
      desired_status == "success" and
          (event.amount_minor != payout.amount_minor or event.currency != payout.currency) ->
        Repo.rollback(:amount_mismatch)

      payout.status == desired_status ->
        %{
          already_settled: true,
          transfer_status: desired_status,
          reference: payout.reference
        }

      desired_status in ["success", "failed"] and
          payout.status in ["success", "failed", "reversed"] ->
        %{
          ignored: true,
          reason: "terminal_transfer_status",
          transfer_status: payout.status,
          reference: payout.reference
        }

      desired_status == "reversed" and payout.status == "failed" ->
        %{
          ignored: true,
          reason: "terminal_transfer_status",
          transfer_status: payout.status,
          reference: payout.reference
        }

      true ->
        finalize_transfer!(payout, event, desired_status)

        %{
          settled: true,
          transfer_status: desired_status,
          reference: payout.reference
        }
    end
  end

  defp lock_transfer(reference) do
    case Ecto.UUID.cast(reference) do
      {:ok, uuid} ->
        case Repo.query(
               """
               SELECT id, user_id, reference::text, amount, currency, status::text,
                      paystack_transfer_code
               FROM public.cleaner_payouts
               WHERE reference = $1::uuid
               LIMIT 1
               FOR UPDATE
               """,
               [uuid]
             ) do
          {:ok, %{rows: [[id, user_id, reference, amount, currency, status, transfer_code]]}} ->
            %{
              id: id,
              user_id: user_id,
              reference: reference,
              amount_minor: amount_to_integer(amount),
              currency: normalize_currency(currency),
              status: status,
              transfer_code: transfer_code
            }

          {:ok, %{rows: []}} ->
            nil

          {:error, error} ->
            Repo.rollback(error)
        end

      :error ->
        nil
    end
  end

  defp finalize_transfer!(payout, event, desired_status) do
    error_message =
      if desired_status in ["failed", "reversed"] do
        event.failure_reason || event.gateway_response
      else
        nil
      end

    transfer_code = event.transfer_code || payout.transfer_code

    case Repo.query(
           """
           SELECT public.fn_finalize_withdrawal(
             $1::text,
             $2::public.withdrawal_status,
             $3::text,
             $4::text
           )
           """,
           [payout.reference, desired_status, error_message, transfer_code]
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Repo.rollback(error)
    end

    case Repo.query(
           """
           UPDATE public.cleaner_payouts
           SET status = $2::public.withdrawal_status,
               paystack_transfer_code = COALESCE($3::text, paystack_transfer_code),
               error_message = $4::text,
               updated_at = NOW()
           WHERE id = $1
           """,
           [payout.id, desired_status, transfer_code, error_message]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> Repo.rollback(:database_unavailable)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp settle_refund(event) do
    Repo.transaction(fn ->
      case lock_refund(event) do
        nil ->
          Logger.info("paystack webhook unknown refund event=#{event.type}")
          %{ignored: true, reason: "unknown_refund"}

        refund ->
          apply_refund(refund, event)
      end
    end)
    |> normalize_transaction()
  end

  defp apply_refund(refund, event) do
    payment_status = DirectCancellation.payment_status_after_refund(refund.refund_percent)
    refund_reference = event.refund_reference

    cond do
      event.type == "refund.processed" and
          (event.amount_minor != refund.refund_amount_minor or event.currency != refund.currency) ->
        Repo.rollback(:amount_mismatch)

      refund.status == "processed" and event.type == "refund.processed" ->
        heal_booking_payment_status(refund.booking_uuid, payment_status)
        maybe_store_refund_reference(refund.id, refund_reference)
        %{already_processed: true, refund_status: "processed"}

      refund.status == "processed" ->
        %{ignored: true, reason: "already_processed", refund_status: "processed"}

      refund.status in ["failed", "manual_review"] and
          event.type in ["refund.pending", "refund.processing"] ->
        %{ignored: true, reason: "non_pending_terminal", refund_status: refund.status}

      event.type in ["refund.pending", "refund.processing"] ->
        update_refund!(refund.id, "pending", refund_reference, nil)
        %{refund_status: "pending"}

      event.type == "refund.needs-attention" ->
        update_refund!(
          refund.id,
          "manual_review",
          refund_reference,
          event.failure_reason ||
            "Paystack refund needs attention (customer bank details may be required)."
        )

        %{refund_status: "manual_review"}

      event.type == "refund.failed" ->
        update_refund!(
          refund.id,
          "failed",
          refund_reference,
          event.failure_reason || "Paystack reported refund.failed."
        )

        %{refund_status: "failed"}

      event.type == "refund.processed" ->
        reason =
          if is_nil(payment_status),
            do: "Unhandled refund_percent=#{refund.refund_percent} on refund.processed",
            else: nil

        update_refund!(refund.id, "processed", refund_reference, reason)
        heal_booking_payment_status(refund.booking_uuid, payment_status)

        %{
          refund_status: "processed",
          payment_status: payment_status,
          settled: not is_nil(payment_status)
        }

      true ->
        %{ignored: true, reason: "unknown_event"}
    end
  end

  defp lock_attempt(reference) do
    case Repo.query(
           """
           SELECT pa.id, pa.booking_id, pa.reference, pa.status, pa.amount_minor, pa.currency,
                  b.status::text, b.payment_status, b.reference
           FROM public.payment_attempts pa
           JOIN public.bookings b ON b.id = pa.booking_id
           WHERE pa.reference = $1
           FOR UPDATE OF b, pa
           """,
           [reference]
         ) do
      {:ok, %{rows: [row]}} ->
        [
          attempt_id,
          booking_uuid,
          reference,
          status,
          amount_minor,
          currency,
          booking_status,
          payment_status,
          booking_reference
        ] = row

        %{
          attempt_id: attempt_id,
          booking_uuid: booking_uuid,
          booking_id: encode_uuid(booking_uuid),
          reference: reference,
          state: status,
          amount_minor: amount_to_integer(amount_minor),
          currency: normalize_currency(currency),
          booking_status: booking_status,
          payment_status: payment_status,
          booking_reference: booking_reference
        }

      {:ok, %{rows: []}} ->
        nil

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp lock_refund(%{refund_reference: refund_reference} = event)
       when is_binary(refund_reference) do
    lock_refund_by("br.paystack_refund_reference = $1", refund_reference) ||
      lock_refund_by(
        "br.paystack_refund_reference IS NULL AND br.paystack_transaction_reference = $1",
        event.transaction_reference
      )
  end

  defp lock_refund(event) do
    lock_refund_by("br.paystack_transaction_reference = $1", event.transaction_reference)
  end

  defp lock_refund_by(_sql, nil), do: nil

  defp lock_refund_by(where, value) do
    case Repo.query(
           """
           SELECT br.id, br.booking_id, br.refund_percent, br.refund_amount_minor, br.status,
                  COALESCE(b.currency, 'GHS')
           FROM public.booking_refunds br
           JOIN public.bookings b ON b.id = br.booking_id
           WHERE #{where}
           ORDER BY br.created_at DESC NULLS LAST
           LIMIT 1
           FOR UPDATE
           """,
           [value]
         ) do
      {:ok, %{rows: [[id, booking_uuid, percent, amount_minor, status, currency]]}} ->
        %{
          id: id,
          booking_uuid: booking_uuid,
          refund_percent: percent,
          refund_amount_minor: amount_to_integer(amount_minor),
          currency: normalize_currency(currency),
          status: status
        }

      {:ok, %{rows: []}} ->
        nil

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp update_refund!(id, status, refund_reference, failure_reason) do
    case Repo.query(
           """
           UPDATE public.booking_refunds
           SET status = $2,
               paystack_refund_reference = COALESCE($3, paystack_refund_reference),
               failure_reason = $4,
               updated_at = now()
           WHERE id = $1
           """,
           [id, status, refund_reference, failure_reason]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp maybe_store_refund_reference(_id, nil), do: :ok

  defp maybe_store_refund_reference(id, refund_reference) do
    case Repo.query(
           """
           UPDATE public.booking_refunds
           SET paystack_refund_reference = COALESCE(paystack_refund_reference, $2),
               updated_at = now()
           WHERE id = $1
           """,
           [id, refund_reference]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp heal_booking_payment_status(_booking_uuid, nil), do: :ok

  defp heal_booking_payment_status(booking_uuid, payment_status) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET payment_status = $2,
               updated_at = now()
           WHERE id = $1
             AND payment_status IS DISTINCT FROM $2
           """,
           [booking_uuid, payment_status]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp parse_event(payload) when is_map(payload) do
    type = string_field(payload, "event")
    data = map_field(payload, "data")

    if type == "" do
      {:error, :invalid_payload}
    else
      {:ok,
       %{
         type: type,
         reference:
           nullable_string(data, "reference") || nullable_string(data, "transaction_reference"),
         transaction_reference: nullable_string(data, "transaction_reference"),
         refund_reference: refund_reference(data),
         amount_minor: integer_field(data, "amount"),
         currency: currency_field(data),
         status: status_field(data),
         gateway_response: nullable_string(data, "gateway_response"),
         failure_reason: nullable_string(data, "message") || nullable_string(data, "reason"),
         transfer_code: nullable_string(data, "transfer_code")
       }}
    end
  end

  defp decode_payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp webhook_secret do
    case Application.get_env(:mithril, :paystack_secret_key) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :not_configured}
    end
  end

  defp refund_reference(data) do
    nullable_string(data, "refund_reference") ||
      case data["id"] do
        id when is_integer(id) -> Integer.to_string(id)
        id when is_binary(id) -> String.trim(id)
        _ -> nil
      end
      |> empty_to_nil()
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp paid?(status) when is_binary(status) do
    String.downcase(status) in ~w(paid post_paid refunded partially_refunded)
  end

  defp paid?(_), do: false

  defp string_field(map, key) when is_map(map) do
    case map[key] do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp nullable_string(map, key) do
    case string_field(map, key) do
      "" -> nil
      value -> value
    end
  end

  defp map_field(map, key) when is_map(map) do
    case map[key] do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp integer_field(map, key) when is_map(map) do
    case map[key] do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        round(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp currency_field(data) do
    case nullable_string(data, "currency") do
      nil -> nil
      currency -> String.upcase(currency)
    end
  end

  defp status_field(data) do
    case nullable_string(data, "status") do
      nil -> nil
      status -> String.downcase(status)
    end
  end

  defp amount_to_integer(value) when is_integer(value), do: value
  defp amount_to_integer(%Decimal{} = value), do: Decimal.to_integer(Decimal.round(value, 0))
  defp amount_to_integer(value) when is_float(value), do: round(value)
  defp amount_to_integer(_), do: 0

  defp normalize_currency(value) when is_binary(value), do: String.upcase(value)
  defp normalize_currency(_), do: "GHS"

  defp encode_uuid(nil), do: nil

  defp encode_uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}

  defp normalize_transaction({:error, reason}) do
    Logger.error("paystack webhook database error: #{inspect(reason)}")
    {:error, :database_unavailable}
  end
end
