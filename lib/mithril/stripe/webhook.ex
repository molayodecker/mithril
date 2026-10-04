defmodule Mithril.Stripe.Webhook do
  @moduledoc false

  require Logger

  alias Mithril.Repo
  alias Mithril.Stripe

  @tolerance_seconds 300
  @settled_statuses ~w(paid post_paid refunded partially_refunded)

  def handle(raw_body, signature) when is_binary(raw_body) do
    with {:ok, secret} <- webhook_secret(),
         :ok <- verify_signature(raw_body, signature, secret),
         {:ok, payload} <- Jason.decode(raw_body),
         {:ok, event_type, intent} <- parse_event(payload) do
      case event_type do
        "payment_intent.succeeded" -> reconcile_succeeded(intent)
        _ -> {:ok, %{event: event_type, ignored: true}}
      end
    else
      {:error, %Jason.DecodeError{}} ->
        {:error, :invalid_json}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(_, _), do: {:error, :invalid_payload}

  @doc false
  def reconcile_succeeded(intent) when is_map(intent) do
    payment_intent_id = string(intent["id"])
    amount_minor = integer(intent["amount_received"] || intent["amount"])
    currency = intent["currency"] |> string() |> String.downcase()
    metadata = if is_map(intent["metadata"]), do: intent["metadata"], else: %{}

    with true <- payment_intent_id != "",
         true <- amount_minor > 0,
         true <- currency != "",
         {:ok, result} <-
           settle(payment_intent_id, amount_minor, currency, metadata) do
      {:ok, Map.put(result, :event, "payment_intent.succeeded")}
    else
      false ->
        {:error, :invalid_payload}

      {:error, :stale_attempt} ->
        case Stripe.refund_payment_intent(payment_intent_id) do
          :ok ->
            {:ok, %{event: "payment_intent.succeeded", refunded: true, settled: false}}

          {:error, reason} ->
            Logger.error("Stripe stale PaymentIntent refund failed: #{inspect(reason)}")
            {:error, :provider_unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle(payment_intent_id, stripe_amount_minor, stripe_currency, metadata) do
    Repo.transaction(fn ->
      case lock_attempt(payment_intent_id) do
        nil ->
          %{ignored: true, reason: "unknown_payment_intent"}

        attempt ->
          validate_attempt!(attempt, stripe_amount_minor, stripe_currency, metadata)

          cond do
            attempt.state in ["superseded", "failed"] ->
              Repo.rollback(:stale_attempt)

            attempt.booking_status == "cancelled" ->
              Repo.rollback(:stale_attempt)

            settled?(attempt.payment_status) and attempt.payment_method != "stripe" ->
              Repo.rollback(:stale_attempt)

            settled?(attempt.payment_status) and attempt.booking_reference == attempt.reference ->
              mark_attempt_paid!(attempt.attempt_id)
              %{already_paid: true, settled: true, reference: attempt.reference}

            settled?(attempt.payment_status) ->
              Repo.rollback(:payment_conflict)

            attempt.state not in ["initializing", "ready", "paid"] ->
              Repo.rollback(:stale_attempt)

            attempt.booking_reference != attempt.reference ->
              Repo.rollback(:payment_reference_mismatch)

            true ->
              mark_attempt_paid!(attempt.attempt_id)
              mark_booking_paid!(attempt.booking_uuid, attempt.reference)
              %{settled: true, reference: attempt.reference}
          end
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, error} ->
        Logger.error("Stripe webhook database error: #{inspect(error)}")
        {:error, :database_unavailable}
    end
  end

  defp lock_attempt(payment_intent_id) do
    case Repo.query(
           """
           SELECT pa.id, pa.booking_id, pa.reference, pa.status, pa.amount_minor, pa.currency,
                  b.payment_status, b.payment_method, b.reference, b.status::text
           FROM public.payment_attempts pa
           JOIN public.bookings b ON b.id = pa.booking_id
           WHERE pa.provider = 'stripe'
             AND pa.stripe_payment_intent_id = $1
           LIMIT 1
           FOR UPDATE OF pa, b
           """,
           [payment_intent_id]
         ) do
      {:ok,
       %{
         rows: [
           [
             attempt_id,
             booking_uuid,
             reference,
             state,
             amount_minor,
             currency,
             payment_status,
             payment_method,
             booking_reference,
             booking_status
           ]
         ]
       }} ->
        %{
          attempt_id: attempt_id,
          booking_uuid: booking_uuid,
          booking_id: Ecto.UUID.load!(booking_uuid),
          reference: reference,
          state: to_string(state),
          amount_minor: amount_to_integer(amount_minor),
          currency: currency |> to_string() |> String.downcase(),
          payment_status: payment_status |> to_string() |> String.downcase(),
          payment_method:
            payment_method
            |> to_string()
            |> String.trim()
            |> String.downcase(),
          booking_reference: booking_reference,
          booking_status: booking_status |> to_string() |> String.downcase()
        }

      {:ok, %{rows: []}} ->
        nil

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp validate_attempt!(attempt, stripe_amount_minor, stripe_currency, metadata) do
    metadata_booking_id = string(metadata["booking_id"])
    metadata_reference = string(metadata["reference"])
    metadata_source_amount = integer(metadata["booking_amount_minor"])
    metadata_source_currency = metadata["booking_currency"] |> string() |> String.downcase()
    metadata_stripe_amount = integer(metadata["stripe_charge_amount_minor"])
    metadata_stripe_currency = metadata["stripe_charge_currency"] |> string() |> String.downcase()

    cond do
      metadata_booking_id != attempt.booking_id -> Repo.rollback(:payment_reference_mismatch)
      metadata_reference != attempt.reference -> Repo.rollback(:payment_reference_mismatch)
      metadata_source_amount != attempt.amount_minor -> Repo.rollback(:amount_mismatch)
      metadata_source_currency != attempt.currency -> Repo.rollback(:amount_mismatch)
      metadata_stripe_amount != stripe_amount_minor -> Repo.rollback(:amount_mismatch)
      metadata_stripe_currency != stripe_currency -> Repo.rollback(:amount_mismatch)
      true -> :ok
    end
  end

  defp mark_attempt_paid!(attempt_id) do
    case Repo.query(
           """
           UPDATE public.payment_attempts
           SET status = 'paid',
               paid_at = COALESCE(paid_at, now()),
               updated_at = now()
           WHERE id = $1
           RETURNING id
           """,
           [attempt_id]
         ) do
      {:ok, %{rows: [[_]]}} -> :ok
      {:ok, %{rows: []}} -> Repo.rollback(:database_unavailable)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp mark_booking_paid!(booking_uuid, reference) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET payment_status = 'paid',
               payment_method = 'stripe',
               updated_at = now()
           WHERE id = $1
             AND reference = $2
           RETURNING id
           """,
           [booking_uuid, reference]
         ) do
      {:ok, %{rows: [[_]]}} -> :ok
      {:ok, %{rows: []}} -> Repo.rollback(:payment_reference_mismatch)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp verify_signature(raw_body, signature, secret)
       when is_binary(signature) and is_binary(secret) do
    parts =
      signature
      |> String.split(",", trim: true)
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> Map.update(acc, key, [value], &[value | &1])
          _ -> acc
        end
      end)

    with [timestamp_text | _] <- Map.get(parts, "t", []),
         {timestamp, ""} <- Integer.parse(timestamp_text),
         true <- abs(System.system_time(:second) - timestamp) <= @tolerance_seconds,
         signatures when is_list(signatures) and signatures != [] <- Map.get(parts, "v1", []),
         expected <-
           :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
           |> Base.encode16(case: :lower),
         true <- Enum.any?(signatures, &secure_equal?(&1, expected)) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp verify_signature(_, _, _), do: {:error, :unauthorized}

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  defp parse_event(%{"type" => type, "data" => %{"object" => intent}})
       when is_binary(type) and is_map(intent),
       do: {:ok, type, intent}

  defp parse_event(_), do: {:error, :invalid_payload}

  defp webhook_secret do
    case Application.get_env(:mithril, :stripe_webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :not_configured}
    end
  end

  defp settled?(status), do: status in @settled_statuses

  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(_), do: ""

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp integer(_), do: 0

  defp amount_to_integer(value) when is_integer(value), do: value
  defp amount_to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp amount_to_integer(_), do: 0
end
