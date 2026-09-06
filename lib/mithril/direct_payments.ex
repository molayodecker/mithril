defmodule Mithril.DirectPayments do
  @moduledoc """
  Direct Paystack checkout for pending bookings.

  Amount and currency always come from the stored booking snapshot. The live
  `reserve_booking_payment_attempt` / `complete_booking_payment_attempt`
  functions keep checkout idempotent with the rest of Instaclean.
  """

  require Logger

  alias Mithril.Paystack
  alias Mithril.Repo

  def initialize(user_id, booking_id, params) when is_map(params) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, callback_url} <- validate_callback_url(params["callbackUrl"], booking_id),
         {:ok, booking} <- fetch_owned_booking(customer_id, bid),
         :ok <- ensure_payable(booking),
         {:ok, email} <- customer_email(customer_id, user_id),
         {:ok, attempt} <- reserve_attempt(booking),
         {:ok, checkout} <- ensure_checkout(attempt, booking, email, callback_url) do
      {:ok, checkout}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(user_id, booking_id, params) when is_map(params) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, booking} <- fetch_owned_booking(customer_id, bid),
         {:ok, reference} <- payment_reference(booking, params),
         {:ok, receipt} <- Paystack.verify(reference),
         :ok <- assert_successful_payment(booking, receipt),
         :ok <- mark_paid(bid, reference) do
      {:ok,
       %{
         id: booking_id,
         status: "pending",
         paymentStatus: "paid",
         amountMinor: booking.amount_minor,
         currency: booking.currency,
         reference: reference
       }}
    else
      :error -> {:error, :not_found}
      {:error, :already_paid} -> already_paid_result(user_id, booking_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp already_paid_result(user_id, booking_id) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, booking} <- fetch_owned_booking(customer_id, bid) do
      {:ok,
       %{
         id: booking_id,
         status: "pending",
         paymentStatus: booking.payment_status,
         amountMinor: booking.amount_minor,
         currency: booking.currency,
         reference: booking.reference
       }}
    else
      _ -> {:error, :already_paid}
    end
  end

  defp ensure_payable(%{payment_status: status}) do
    if paid?(status), do: {:error, :already_paid}, else: :ok
  end

  defp ensure_checkout(
         %{state: "ready", authorization_url: url} = attempt,
         booking,
         _email,
         _callback_url
       )
       when is_binary(url) and url != "" do
    {:ok, checkout_payload(attempt, booking)}
  end

  defp ensure_checkout(%{state: "settled"}, _booking, _email, _callback_url) do
    {:error, :already_paid}
  end

  defp ensure_checkout(%{state: "conflict"}, _booking, _email, _callback_url) do
    {:error, :payment_conflict}
  end

  defp ensure_checkout(%{state: "stale"} = attempt, booking, email, callback_url) do
    _ = fail_attempt(attempt.attempt_id, "stale initializing attempt")

    with {:ok, retry} <- reserve_attempt(booking) do
      ensure_checkout(retry, booking, email, callback_url)
    end
  end

  defp ensure_checkout(attempt, booking, email, callback_url) do
    attrs = %{
      email: email,
      amount: booking.amount_minor,
      currency: booking.currency,
      reference: attempt.reference,
      callback_url: callback_url,
      metadata: %{
        booking_id: booking.id,
        source: "instaclean_direct"
      }
    }

    case Paystack.initialize(attrs) do
      {:ok, provider} ->
        complete_attempt(attempt.attempt_id, provider, booking)

      {:error, :payment_not_configured} ->
        {:error, :payment_not_configured}

      {:error, {:provider, status, message}} ->
        _ = fail_attempt(attempt.attempt_id, "Paystack #{status}: #{message}")
        {:error, :payment_failed}

      {:error, :provider_unavailable} ->
        {:error, :payment_failed}

      {:error, reason} ->
        Logger.warning("Direct Paystack initialize failed: #{inspect(reason)}")
        {:error, :payment_failed}
    end
  end

  defp complete_attempt(attempt_id, provider, booking) do
    case Repo.query(
           """
           SELECT state, reference, authorization_url, access_code, payment_status
           FROM public.complete_booking_payment_attempt($1::uuid, $2::text, $3::text, $4::text)
           """,
           [
             attempt_id,
             provider.authorization_url,
             provider.access_code,
             provider.reference
           ]
         ) do
      {:ok, %{rows: [[state, reference, authorization_url, access_code, payment_status]]}} ->
        {:ok,
         checkout_payload(
           %{
             state: state,
             reference: reference,
             authorization_url: authorization_url,
             access_code: access_code,
             payment_status: payment_status,
             amount_minor: booking.amount_minor,
             currency: booking.currency
           },
           booking
         )}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp reserve_attempt(booking) do
    fingerprint = "direct:#{booking.id}:#{booking.amount_minor}:#{booking.currency}"

    case Repo.query(
           """
           SELECT attempt_id, created, state, reference, authorization_url, access_code,
                  payment_status, expires_at, amount_minor, currency, request_fingerprint
           FROM public.reserve_booking_payment_attempt($1::uuid, $2::text, $3::bigint, $4::text)
           """,
           [booking.uuid, fingerprint, booking.amount_minor, booking.currency]
         ) do
      {:ok, %{rows: [row]}} ->
        [
          attempt_id,
          _created,
          state,
          reference,
          authorization_url,
          access_code,
          payment_status,
          _expires_at,
          amount_minor,
          currency,
          _fingerprint
        ] = row

        {:ok,
         %{
           attempt_id: attempt_id,
           state: state,
           reference: reference,
           authorization_url: authorization_url,
           access_code: access_code,
           payment_status: payment_status,
           amount_minor: amount_minor,
           currency: currency
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fail_attempt(nil, _reason), do: false

  defp fail_attempt(attempt_id, reason) do
    case Repo.query(
           "SELECT public.fail_booking_payment_attempt($1::uuid, $2::text)",
           [attempt_id, reason]
         ) do
      {:ok, _} ->
        true

      {:error, error} ->
        Logger.warning("Direct payment attempt fail failed: #{inspect(error)}")
        false
    end
  end

  defp fetch_owned_booking(customer_id, booking_id) do
    case Repo.query(
           """
           SELECT id, payment_status, COALESCE(final_amount_minor, total_price),
                  COALESCE(currency, 'GHS'), reference
           FROM public.bookings
           WHERE id = $1 AND customer_id = $2
           LIMIT 1
           """,
           [booking_id, customer_id]
         ) do
      {:ok, %{rows: [[id, payment_status, amount_minor, currency, reference]]}} ->
        {:ok,
         %{
           id: Ecto.UUID.load!(id),
           uuid: id,
           payment_status: payment_status,
           amount_minor: amount_to_integer(amount_minor),
           currency: currency || "GHS",
           reference: reference
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp customer_email(customer_id, user_id) do
    case Repo.query(
           "SELECT email FROM public.users WHERE id = $1::uuid LIMIT 1",
           [customer_id]
         ) do
      {:ok, %{rows: [[email]]}} when is_binary(email) ->
        case String.trim(email) do
          "" -> {:ok, fallback_email(user_id)}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _} ->
        {:ok, fallback_email(user_id)}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fallback_email(user_id), do: "direct+#{user_id}@customers.tryinstaclean.com"

  defp payment_reference(booking, params) do
    cond do
      paid?(booking.payment_status) ->
        {:error, :already_paid}

      is_binary(params["reference"]) and String.trim(params["reference"]) != "" ->
        {:ok, String.trim(params["reference"])}

      is_binary(booking.reference) and booking.reference != "" ->
        {:ok, booking.reference}

      true ->
        {:error, :payment_not_started}
    end
  end

  defp assert_successful_payment(booking, receipt) do
    amount = amount_to_integer(receipt[:amount] || receipt["amount"])
    currency = receipt[:currency] || receipt["currency"]
    status = receipt[:status] || receipt["status"]

    cond do
      status != "success" ->
        {:error, :payment_incomplete}

      amount != booking.amount_minor ->
        {:error, :amount_mismatch}

      is_binary(currency) and String.upcase(currency) != String.upcase(booking.currency) ->
        {:error, :amount_mismatch}

      true ->
        :ok
    end
  end

  defp mark_paid(booking_id, reference) do
    Repo.transaction(fn ->
      with {:ok, _} <-
             Repo.query(
               """
               UPDATE public.bookings
               SET payment_status = 'paid',
                   payment_method = 'paystack',
                   reference = COALESCE(reference, $2),
                   updated_at = now()
               WHERE id = $1
                 AND lower(coalesce(payment_status, '')) NOT IN (
                   'paid', 'post_paid', 'refunded', 'partially_refunded'
                 )
               """,
               [booking_id, reference]
             ),
           {:ok, _} <-
             Repo.query(
               """
               UPDATE public.payment_attempts
               SET status = 'paid',
                   paid_at = coalesce(paid_at, now()),
                   updated_at = now()
               WHERE booking_id = $1
                 AND reference = $2
                 AND status IN ('initializing', 'ready')
               """,
               [booking_id, reference]
             ) do
        :ok
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp validate_callback_url(value, booking_id) when is_binary(value) do
    value = String.trim(value)

    with {:ok, uri} <- parse_absolute_url(value),
         true <- allowed_callback_host?(uri.host),
         true <- allowed_callback_scheme?(uri),
         true <- callback_path?(uri.path, booking_id) do
      {:ok, value}
    else
      _ -> {:error, :invalid_callback_url}
    end
  end

  defp validate_callback_url(_value, _booking_id), do: {:error, :invalid_callback_url}

  defp parse_absolute_url(value) do
    uri = URI.parse(value)

    if is_binary(uri.scheme) and is_binary(uri.host) do
      {:ok, uri}
    else
      :error
    end
  end

  defp allowed_callback_host?(host) when is_binary(host) do
    host = String.downcase(host)

    host in ["localhost", "127.0.0.1"] or
      String.ends_with?(host, ".tryinstaclean.com") or
      host == "tryinstaclean.com" or
      String.ends_with?(host, ".vercel.app")
  end

  defp allowed_callback_scheme?(%URI{scheme: "https"}), do: true

  defp allowed_callback_scheme?(%URI{scheme: "http", host: host})
       when host in ["localhost", "127.0.0.1"],
       do: true

  defp allowed_callback_scheme?(_), do: false

  defp callback_path?(path, booking_id) when is_binary(path) do
    String.trim_trailing(path, "/") == "/bookings/#{booking_id}"
  end

  defp callback_path?(_, _), do: false

  defp checkout_payload(attempt, booking) do
    %{
      authorizationUrl: attempt.authorization_url,
      accessCode: attempt.access_code,
      reference: attempt.reference,
      paymentStatus: attempt[:payment_status] || booking.payment_status,
      amountMinor: attempt[:amount_minor] || booking.amount_minor,
      currency: attempt[:currency] || booking.currency
    }
  end

  defp paid?(status) when is_binary(status) do
    String.downcase(status) in ~w(paid post_paid refunded partially_refunded)
  end

  defp paid?(_), do: false

  defp amount_to_integer(value) when is_integer(value), do: value
  defp amount_to_integer(%Decimal{} = value), do: Decimal.to_integer(value)

  defp amount_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp amount_to_integer(_), do: 0

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_value), do: :error

  defp database_error(error) do
    Logger.error("Direct payments database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
