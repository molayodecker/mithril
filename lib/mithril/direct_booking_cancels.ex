defmodule Mithril.DirectBookingCancels do
  @moduledoc """
  Customer cancel + Paystack refund for Direct bookings.

  Booking status is cancelled immediately. Paid refunds stay `paid` until the
  existing Paystack refund webhook settles `booking_refunds` and flips
  `payment_status` to `refunded` or `partially_refunded`.
  """

  require Logger

  alias Mithril.DirectCancellation
  alias Mithril.Paystack
  alias Mithril.Repo

  def cancel(user_id, booking_id, params \\ %{}, actor \\ :customer)

  def cancel(user_id, booking_id, params, :customer) when is_map(params) do
    do_cancel(user_id, booking_id, params, :customer)
  end

  def cancel(user_id, booking_id, params, {:admin, admin_id})
      when is_map(params) and is_binary(admin_id) do
    do_cancel(user_id, booking_id, params, {:admin, admin_id})
  end

  defp do_cancel(user_id, booking_id, params, actor) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, actor} <- actor_record(actor, customer_id),
         {:ok, reason} <- cancellation_reason(params),
         {:ok, result} <- persist_cancel(customer_id, bid, reason, actor) do
      finalize_paystack_refund(result)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_cancel(customer_id, booking_id, reason, actor) do
    Repo.transaction(fn ->
      with {:ok, booking} <- lock_owned_booking(customer_id, booking_id),
           :ok <- ensure_cancellable_or_replay(booking),
           {:ok, existing} <- existing_refund(booking_id, customer_id) do
        cond do
          existing ->
            replay_payload(booking, existing)

          booking.status == "cancelled" ->
            already_cancelled_payload(booking)

          true ->
            policy = DirectCancellation.evaluate(booking)

            with :ok <- ensure_processed_refunds_reconciled(booking_id, policy),
                 :ok <- ensure_no_actionable_direct_refund_request(booking_id, policy) do
              case apply_cancel(booking, customer_id, reason, actor, policy) do
                {:error, {:replay_refund, existing}} -> replay_payload(booking, existing)
                {:error, reason} -> Repo.rollback(reason)
                result -> result
              end
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction()
  end

  defp ensure_cancellable_or_replay(booking) do
    if booking.status == "cancelled" do
      :ok
    else
      policy = DirectCancellation.evaluate(booking)

      if policy.can_cancel do
        :ok
      else
        {:error, {:not_cancellable, policy.error_message}}
      end
    end
  end

  defp apply_cancel(booking, customer_id, reason, actor, policy) do
    with {:ok, _} <- mark_cancelled(booking.id, customer_id, actor, policy.tier, reason),
         {:ok, refund} <- insert_refund(booking, customer_id, policy, actor) do
      payload(booking, policy, refund.status, refund.id)
    else
      {:error, :cancel_conflict} ->
        {:error,
         {:cancel_conflict,
          "This booking can no longer be cancelled. It may have already started or been cancelled."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_owned_booking(customer_id, booking_id) do
    case Repo.query(
           """
           SELECT
             id::text,
             status,
             payment_status,
             scheduled_date,
             scheduled_time,
             COALESCE(final_amount_minor, total_price) AS amount_minor,
             COALESCE(currency, 'GHS') AS currency,
             NULLIF(btrim(reference), '') AS reference,
             COALESCE(
               NULLIF(btrim(to_jsonb(b)->>'timezone_name'), ''),
               NULLIF(btrim(to_jsonb(b)->>'timezone'), ''),
               'Africa/Accra'
             ) AS timezone
           FROM public.bookings b
           WHERE id = $1 AND customer_id = $2
           FOR UPDATE
           """,
           [booking_id, customer_id]
         ) do
      {:ok, %{rows: [row]}} ->
        {:ok, hydrate_booking(row)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp hydrate_booking([
         id,
         status,
         payment_status,
         scheduled_date,
         scheduled_time,
         amount_minor,
         currency,
         reference,
         timezone
       ]) do
    service_timezone = timezone || "Africa/Accra"
    scheduled_at = scheduled_at(scheduled_date, scheduled_time, service_timezone)
    local_today = local_today(service_timezone)

    %{
      id: id,
      uuid: id,
      status: status,
      payment_status: payment_status,
      scheduled_date: scheduled_date,
      scheduled_at: scheduled_at,
      local_today: local_today,
      amount_minor: amount_to_integer(amount_minor),
      currency: currency || "GHS",
      reference: reference
    }
  end

  defp scheduled_at(%Date{} = date, time, timezone) do
    time = time || ~T[00:00:00]

    case Repo.query(
           "SELECT ($1::date + $2::time) AT TIME ZONE $3::text",
           [date, time, timezone]
         ) do
      {:ok, %{rows: [[%DateTime{} = at]]}} -> at
      {:ok, %{rows: [[%NaiveDateTime{} = at]]}} -> DateTime.from_naive!(at, "Etc/UTC")
      _ -> nil
    end
  end

  defp scheduled_at(_, _, _), do: nil

  defp local_today(timezone) do
    case Repo.query("SELECT (now() AT TIME ZONE $1::text)::date", [timezone]) do
      {:ok, %{rows: [[%Date{} = today]]}} -> today
      _ -> Date.utc_today()
    end
  end

  defp ensure_processed_refunds_reconciled(_booking_id, %{refund_amount_minor: amount})
       when not is_integer(amount) or amount <= 0,
       do: :ok

  defp ensure_processed_refunds_reconciled(booking_id, _policy) do
    case Repo.query(
           """
           SELECT 1
           FROM public.direct_refund_requests drr
           WHERE drr.booking_id = $1
             AND drr.status = 'processed'
             AND (
               drr.canonical_refunded_amount_minor_at_request IS NULL
               OR COALESCE((
                    SELECT SUM(br.refund_amount_minor)::bigint
                    FROM public.booking_refunds br
                    WHERE br.booking_id = drr.booking_id
                      AND br.status = 'processed'
                  ), 0)::bigint
                  < drr.canonical_refunded_amount_minor_at_request
                    + COALESCE(drr.proposed_refund_amount_minor, 0)
             )
           LIMIT 1
           """,
           [booking_id]
         ) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: [[1]]}} ->
        {:error,
         {:refund_reconciliation_pending,
          "A processed refund is still being reconciled. Try again after reconciliation completes."}}

      {:error, error} ->
        database_error(error)
    end
  end

  defp ensure_no_actionable_direct_refund_request(_booking_id, %{refund_amount_minor: amount})
       when not is_integer(amount) or amount <= 0,
       do: :ok

  defp ensure_no_actionable_direct_refund_request(booking_id, _policy) do
    case Repo.query(
           """
           SELECT 1
           FROM public.direct_refund_requests
           WHERE booking_id = $1
             AND status IN ('requested', 'reviewing', 'approved', 'processing')
           LIMIT 1
           """,
           [booking_id]
         ) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: [[1]]}} ->
        {:error,
         {:refund_request_conflict,
          "This booking already has a refund request in progress. Resolve it before cancelling."}}

      {:error, error} ->
        database_error(error)
    end
  end

  defp existing_refund(booking_id, customer_id) do
    case Repo.query(
           """
           SELECT id::text, tier, refund_percent, refund_amount_minor, status
           FROM public.booking_refunds
           WHERE booking_id = $1 AND customer_id = $2
           LIMIT 1
           """,
           [booking_id, customer_id]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[id, tier, percent, amount, status]]}} ->
        {:ok,
         %{
           id: id,
           tier: tier,
           refund_percent: amount_to_integer(percent),
           refund_amount_minor: amount_to_integer(amount),
           status: status
         }}

      {:error, error} ->
        database_error(error)
    end
  end

  defp mark_cancelled(booking_id, customer_id, actor, tier, reason) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET status = 'cancelled',
               cancelled_at = now(),
               cancelled_by = $2,
               cancelled_by_role = $3,
               cancellation_tier = $4,
               cancellation_reason = $5,
               cancellation_reason_code = $6,
               updated_at = now()
           WHERE id = $1
             AND customer_id = $7
             AND status = ANY($8::text[])
           RETURNING id
           """,
           [
             dump!(booking_id),
             actor.id,
             actor.role,
             tier,
             reason,
             actor.reason_code,
             customer_id,
             DirectCancellation.cancellable_statuses()
           ]
         ) do
      {:ok, %{rows: [[_id]]}} ->
        {:ok, :cancelled}

      {:ok, %{rows: []}} ->
        {:error, :cancel_conflict}

      {:error, error} ->
        database_error(error)
    end
  end

  defp insert_refund(booking, customer_id, policy, actor) do
    needs_paystack =
      policy.is_paid and policy.refund_percent > 0 and policy.refund_amount_minor > 0

    reference = booking.reference

    {status, failure_reason} =
      cond do
        needs_paystack and is_nil(reference) ->
          {"manual_review", "Missing Paystack transaction reference on booking."}

        needs_paystack and not Paystack.configured?() ->
          {"manual_review", "Paystack not configured"}

        needs_paystack ->
          {"pending", nil}

        true ->
          {"skipped", nil}
      end

    case Repo.query(
           """
           INSERT INTO public.booking_refunds (
             booking_id,
             customer_id,
             tier,
             refund_percent,
             refund_amount_minor,
             paystack_transaction_reference,
             status,
             failure_reason,
             refund_attribution_role,
             refund_reason_code
           ) VALUES (
             $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
           )
           RETURNING id::text, status
           """,
           [
             dump!(booking.id),
             customer_id,
             policy.tier,
             policy.refund_percent,
             policy.refund_amount_minor,
             reference,
             status,
             failure_reason,
             actor.role,
             actor.reason_code
           ]
         ) do
      {:ok, %{rows: [[id, stored_status]]}} ->
        {:ok,
         %{id: id, status: stored_status, needs_paystack: needs_paystack and status == "pending"}}

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        case existing_refund(dump!(booking.id), customer_id) do
          {:ok, existing} when not is_nil(existing) -> {:error, {:replay_refund, existing}}
          {:ok, _} -> {:error, :cancel_conflict}
          {:error, reason} -> {:error, reason}
        end

      {:error, error} ->
        database_error(error)
    end
  end

  defp finalize_paystack_refund({:replay, payload}), do: {:ok, payload}

  defp finalize_paystack_refund(%{needs_paystack: false} = result) do
    {:ok, result.payload}
  end

  defp finalize_paystack_refund(result) do
    attrs = %{
      transaction: result.reference,
      amount: result.refund_amount_minor,
      currency: result.currency,
      customer_note: "Instaclean Direct booking cancellation"
    }

    case Paystack.refund(attrs) do
      {:ok, refund} ->
        store_paystack_reference(result.refund_id, refund)
        {:ok, %{result.payload | refundStatus: "pending"}}

      {:error, reason} when reason in [:provider_unavailable, :payment_not_configured] ->
        manual_review_refund(result, reason)

      {:error, {:provider, status, _message} = reason}
      when is_integer(status) and status >= 500 and status <= 599 ->
        manual_review_refund(result, reason)

      {:error, reason} ->
        mark_refund_failed(result.refund_id, reason)

        {:ok,
         %{
           result.payload
           | refundStatus: "failed",
             successMessage:
               DirectCancellation.success_message_for_refund(
                 result.payload.tier,
                 "failed",
                 result.payload.successMessage
               )
         }}
    end
  end

  defp manual_review_refund(result, reason) do
    mark_refund_manual_review(result.refund_id, reason)

    {:ok,
     %{
       result.payload
       | refundStatus: "manual_review",
         successMessage:
           DirectCancellation.success_message_for_refund(
             result.payload.tier,
             "manual_review",
             result.payload.successMessage
           )
     }}
  end

  defp store_paystack_reference(refund_id, refund) do
    reference = paystack_refund_reference(refund)

    Repo.query(
      """
      UPDATE public.booking_refunds
      SET paystack_refund_reference = COALESCE($2, paystack_refund_reference),
          status = 'pending',
          updated_at = now()
      WHERE id = $1 AND status = 'pending'
      """,
      [dump!(refund_id), reference]
    )
  end

  defp mark_refund_manual_review(refund_id, reason) do
    Repo.query(
      """
      UPDATE public.booking_refunds
      SET status = 'manual_review',
          failure_reason = $2,
          updated_at = now()
      WHERE id = $1 AND status = 'pending'
      """,
      [
        dump!(refund_id),
        "Paystack refund outcome is unknown; verify provider state before retrying: #{failure_reason(reason)}"
      ]
    )
  end

  defp mark_refund_failed(refund_id, reason) do
    Repo.query(
      """
      UPDATE public.booking_refunds
      SET status = 'failed',
          failure_reason = $2,
          updated_at = now()
      WHERE id = $1 AND status = 'pending'
      """,
      [dump!(refund_id), failure_reason(reason)]
    )
  end

  defp replay_payload(booking, refund) do
    {:replay,
     %{
       id: booking.id,
       status: booking.status,
       paymentStatus: booking.payment_status,
       currency: booking.currency,
       amountMinor: booking.amount_minor,
       tier: refund.tier,
       refundPercent: refund.refund_percent,
       refundAmountMinor: refund.refund_amount_minor,
       refundStatus: refund.status,
       successMessage:
         DirectCancellation.existing_refund_success_message(%{
           tier: refund.tier,
           refund_status: refund.status,
           refund_percent: refund.refund_percent,
           refund_amount_minor: refund.refund_amount_minor
         })
     }}
  end

  defp already_cancelled_payload(booking) do
    {:replay,
     %{
       id: booking.id,
       status: "cancelled",
       paymentStatus: booking.payment_status,
       currency: booking.currency,
       amountMinor: booking.amount_minor,
       tier: "no_refund",
       refundPercent: 0,
       refundAmountMinor: 0,
       refundStatus: "skipped",
       successMessage: "Your booking has already been cancelled."
     }}
  end

  defp payload(booking, policy, refund_status, refund_id) do
    %{
      payload: %{
        id: booking.id,
        status: "cancelled",
        paymentStatus: booking.payment_status,
        currency: booking.currency,
        amountMinor: booking.amount_minor,
        tier: policy.tier,
        refundPercent: policy.refund_percent,
        refundAmountMinor: policy.refund_amount_minor,
        refundStatus: refund_status,
        successMessage:
          DirectCancellation.success_message_for_refund(
            policy.tier,
            refund_status,
            policy.success_message
          )
      },
      refund_id: refund_id,
      reference: booking.reference,
      refund_amount_minor: policy.refund_amount_minor,
      currency: booking.currency,
      needs_paystack: refund_status == "pending" and policy.refund_amount_minor > 0
    }
  end

  defp cancellation_reason(params) do
    case params["cancellationReason"] || params[:cancellationReason] do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        trimmed = value |> String.trim() |> String.slice(0, 500)
        {:ok, if(trimmed == "", do: nil, else: trimmed)}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp paystack_refund_reference(%{id: id}) when is_integer(id), do: Integer.to_string(id)
  defp paystack_refund_reference(%{id: id}) when is_binary(id) and id != "", do: id
  defp paystack_refund_reference(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp paystack_refund_reference(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp paystack_refund_reference(_), do: nil

  defp failure_reason({:provider, _status, message}) when is_binary(message), do: message
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason), do: inspect(reason)

  defp amount_to_integer(value) when is_integer(value), do: value
  defp amount_to_integer(%Decimal{} = value), do: Decimal.to_integer(Decimal.round(value, 0))
  defp amount_to_integer(value) when is_float(value), do: round(value)

  defp amount_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp amount_to_integer(_), do: 0

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp actor_record(:customer, customer_id) do
    {:ok, %{id: customer_id, role: "customer", reason_code: "customer_cancelled"}}
  end

  defp actor_record({:admin, admin_id}, _customer_id) do
    case dump_uuid(admin_id) do
      {:ok, uid} -> {:ok, %{id: uid, role: "admin", reason_code: "admin_cancelled"}}
      :error -> {:error, :invalid_request}
    end
  end

  defp dump!(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "invalid uuid"
    end
  end

  defp normalize_transaction({:ok, {:replay, payload}}), do: {:ok, {:replay, payload}}
  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp database_error(error) do
    Logger.error("Direct booking cancel database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
