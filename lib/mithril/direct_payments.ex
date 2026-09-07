defmodule Mithril.DirectPayments do
  @moduledoc """
  Direct Paystack checkout for pending bookings.

  Payability and split routing come from the canonical PostgreSQL payable
  snapshot. Payment attempts remain the source of truth for Paystack references,
  so a provider reference can never be reused across bookings.
  """

  require Logger

  alias Mithril.Paystack
  alias Mithril.Repo

  @default_poll_delays_ms [50, 100, 200]
  @terminal_provider_statuses ~w(abandoned failed reversed)

  def initialize(user_id, booking_id, params) when is_map(params) do
    with {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, callback_url} <- validate_callback_url(params["callbackUrl"], booking_id),
         {:ok, booking} <- fetch_payable_booking(user_id, customer_id, bid),
         {:ok, email} <- customer_email(customer_id, user_id),
         {:ok, routing} <- payment_routing(booking),
         {:ok, attempt} <- reserve_attempt(booking),
         {:ok, checkout} <- ensure_checkout(attempt, booking, email, callback_url, routing) do
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
         {:ok, attempt} <- verifiable_attempt(booking, params),
         {:ok, receipt} <- Paystack.verify(attempt.reference),
         :ok <- verify_receipt(attempt, receipt),
         :ok <- mark_paid(bid, attempt) do
      {:ok,
       %{
         id: booking_id,
         status: "pending",
         paymentStatus: "paid",
         amountMinor: attempt.amount_minor,
         currency: attempt.currency,
         reference: attempt.reference
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

  defp ensure_checkout(
         %{state: "ready", authorization_url: url} = attempt,
         booking,
         _email,
         _callback_url,
         _routing
       )
       when is_binary(url) and url != "" do
    {:ok, checkout_payload(attempt, booking)}
  end

  defp ensure_checkout(%{state: "settled"}, _booking, _email, _callback_url, _routing) do
    {:error, :already_paid}
  end

  defp ensure_checkout(%{state: "conflict"}, _booking, _email, _callback_url, _routing) do
    {:error, :payment_conflict}
  end

  defp ensure_checkout(%{state: "stale"} = attempt, booking, email, callback_url, routing) do
    recover_stale_attempt(attempt, booking, email, callback_url, routing)
  end

  defp ensure_checkout(
         %{state: "initializing", created: false} = attempt,
         booking,
         email,
         callback_url,
         routing
       ) do
    wait_for_checkout(attempt, booking, email, callback_url, routing, poll_delays_ms())
  end

  defp ensure_checkout(
         %{state: "initializing", created: true} = attempt,
         booking,
         email,
         callback_url,
         routing
       ) do
    initialize_checkout(attempt, booking, email, callback_url, routing)
  end

  defp ensure_checkout(_attempt, _booking, _email, _callback_url, _routing) do
    {:error, :payment_in_progress}
  end

  defp wait_for_checkout(_attempt, _booking, _email, _callback_url, _routing, []) do
    {:error, :payment_in_progress}
  end

  defp wait_for_checkout(
         _attempt,
         booking,
         email,
         callback_url,
         routing,
         [delay_ms | rest]
       ) do
    if delay_ms > 0, do: Process.sleep(delay_ms)

    with {:ok, current} <- reserve_attempt(booking) do
      case current do
        %{state: "initializing", created: false} ->
          wait_for_checkout(current, booking, email, callback_url, routing, rest)

        _ ->
          ensure_checkout(current, booking, email, callback_url, routing)
      end
    end
  end

  defp recover_stale_attempt(attempt, booking, email, callback_url, routing) do
    case Paystack.verify(attempt.reference) do
      {:ok, receipt} ->
        case provider_status(receipt) do
          "success" ->
            case assert_successful_payment(attempt, receipt) do
              :ok ->
                with :ok <- mark_paid(booking.uuid, attempt) do
                  {:error, :already_paid}
                end

              {:error, reason} ->
                {:error, reason}
            end

          status when status in @terminal_provider_statuses ->
            retire_stale_attempt(
              attempt,
              booking,
              email,
              callback_url,
              routing,
              "Paystack transaction #{status} during stale recovery"
            )

          _ ->
            {:error, :payment_in_progress}
        end

      {:error, :not_found} ->
        retire_stale_attempt(
          attempt,
          booking,
          email,
          callback_url,
          routing,
          "Paystack reference not found during stale recovery"
        )

      {:error, :payment_not_configured} ->
        {:error, :payment_not_configured}

      {:error, _reason} ->
        # A stale local lease does not prove the provider transaction failed.
        # Keep the reference reserved until Paystack can be checked conclusively.
        {:error, :payment_in_progress}
    end
  end

  defp retire_stale_attempt(attempt, booking, email, callback_url, routing, reason) do
    if fail_attempt(attempt.attempt_id, reason) do
      with {:ok, retry} <- reserve_attempt(booking) do
        ensure_checkout(retry, booking, email, callback_url, routing)
      end
    else
      {:error, :database_unavailable}
    end
  end

  defp initialize_checkout(attempt, booking, email, callback_url, routing) do
    attrs =
      %{
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
      |> Map.merge(routing)

    case Paystack.initialize(attrs) do
      {:ok, provider} ->
        complete_attempt(attempt.attempt_id, provider, booking)

      {:error, :payment_not_configured} ->
        {:error, :payment_not_configured}

      {:error, {:provider, status, message}} ->
        _ = fail_attempt(attempt.attempt_id, "Paystack #{status}: #{message}")
        {:error, :payment_failed}

      {:error, :provider_unavailable} ->
        # The request may have reached Paystack even if the response was lost.
        # Leave the attempt initializing so stale recovery verifies it first.
        {:error, :payment_in_progress}

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
          created,
          state,
          reference,
          authorization_url,
          access_code,
          payment_status,
          expires_at,
          amount_minor,
          currency,
          request_fingerprint
        ] = row

        {:ok,
         %{
           attempt_id: attempt_id,
           created: created,
           state: state,
           reference: reference,
           authorization_url: authorization_url,
           access_code: access_code,
           payment_status: payment_status,
           expires_at: expires_at,
           amount_minor: amount_to_integer(amount_minor),
           currency: normalize_currency(currency),
           request_fingerprint: request_fingerprint
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
      {:ok, %{rows: [[true]]}} ->
        true

      {:ok, _} ->
        false

      {:error, error} ->
        Logger.warning("Direct payment attempt fail failed: #{inspect(error)}")
        false
    end
  end

  defp fetch_payable_booking(user_id, customer_id, booking_id) do
    with {:ok, specialty_slug} <- owned_booking_specialty(customer_id, booking_id),
         {:ok, booking} <- canonical_payable_snapshot(user_id, booking_id, specialty_slug) do
      {:ok, booking}
    end
  end

  defp owned_booking_specialty(customer_id, booking_id) do
    case Repo.query(
           """
           SELECT st.specialty_slug
           FROM public.bookings b
           JOIN public.service_types st ON st.id = b.service_id
           WHERE b.id = $1 AND b.customer_id = $2
           LIMIT 1
           """,
           [booking_id, customer_id]
         ) do
      {:ok, %{rows: [[specialty_slug]]}} -> {:ok, specialty_slug}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp canonical_payable_snapshot(user_id, booking_id, specialty_slug) do
    function_name =
      if specialty_slug == "airbnb_turnover" do
        "authorize_airbnb_turnover_payment"
      else
        "get_payable_booking_snapshot"
      end

    query = """
    SELECT booking_id, customer_id, final_amount_minor, currency, payment_status,
           booking_status, payment_reference, payment_split_type, paystack_split_code,
           tax_share_minor, vendor_share_minor, platform_share_minor,
           tax_percentage_bps, vendor_percentage_bps, tax_paystack_share,
           vendor_paystack_share
    FROM public.#{function_name}($1::uuid)
    """

    Repo.transaction(fn ->
      with {:ok, _} <-
             Repo.query("SELECT set_config('request.jwt.claim.sub', $1::text, true)", [user_id]),
           {:ok, result} <- Repo.query(query, [booking_id]) do
        case result.rows do
          [
            [
              id,
              customer_id,
              amount_minor,
              currency,
              payment_status,
              booking_status,
              reference,
              payment_split_type,
              paystack_split_code,
              tax_share_minor,
              vendor_share_minor,
              platform_share_minor,
              tax_percentage_bps,
              vendor_percentage_bps,
              tax_paystack_share,
              vendor_paystack_share
            ]
          ] ->
            %{
              id: Ecto.UUID.load!(id),
              uuid: id,
              customer_uuid: customer_id,
              amount_minor: amount_to_integer(amount_minor),
              currency: normalize_currency(currency),
              payment_status: payment_status,
              booking_status: booking_status,
              reference: reference,
              payment_split_type: payment_split_type,
              paystack_split_code: paystack_split_code,
              tax_share_minor: tax_share_minor,
              vendor_share_minor: vendor_share_minor,
              platform_share_minor: platform_share_minor,
              tax_percentage_bps: tax_percentage_bps,
              vendor_percentage_bps: vendor_percentage_bps,
              tax_paystack_share: tax_paystack_share,
              vendor_paystack_share: vendor_paystack_share
            }

          [] ->
            Repo.rollback(:payment_not_payable)
        end
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, booking} -> {:ok, booking}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp payment_routing(%{paystack_split_code: split_code})
       when is_binary(split_code) and split_code != "" do
    {:ok, %{split_code: String.trim(split_code)}}
  end

  defp payment_routing(booking) do
    tax_subaccount = Application.get_env(:mithril, :paystack_tax_subaccount)
    vendor_subaccount = Application.get_env(:mithril, :paystack_vendor_subaccount)

    with tax when is_binary(tax) and tax != "" <- tax_subaccount,
         vendor when is_binary(vendor) and vendor != "" <- vendor_subaccount,
         {:ok, tax_share} <-
           split_share(booking.tax_share_minor, booking.tax_percentage_bps, booking.amount_minor),
         {:ok, vendor_share} <-
           split_share(
             booking.vendor_share_minor,
             booking.vendor_percentage_bps,
             booking.amount_minor
           ),
         true <- tax_share + vendor_share <= booking.amount_minor do
      {:ok,
       %{
         split: %{
           type: "flat",
           bearer_type: "account",
           subaccounts: [
             %{subaccount: String.trim(tax), share: tax_share},
             %{subaccount: String.trim(vendor), share: vendor_share}
           ]
         }
       }}
    else
      _ -> {:error, :payment_routing_unavailable}
    end
  end

  defp split_share(explicit_minor, _bps, _amount_minor)
       when is_integer(explicit_minor) and explicit_minor >= 0 do
    {:ok, explicit_minor}
  end

  defp split_share(_explicit_minor, bps, amount_minor) do
    with bps when is_integer(bps) and bps >= 0 <- integer_or_nil(bps),
         amount when is_integer(amount) and amount > 0 <- integer_or_nil(amount_minor) do
      {:ok, div(amount * bps, 10_000)}
    else
      _ -> {:error, :invalid_split}
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
           currency: normalize_currency(currency),
           reference: reference
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp verifiable_attempt(booking, params) do
    if paid?(booking.payment_status) do
      {:error, :already_paid}
    else
      reference = requested_reference(params) || normalized_reference(booking.reference)

      cond do
        is_nil(reference) ->
          {:error, :payment_not_started}

        reference != normalized_reference(booking.reference) ->
          {:error, :payment_reference_mismatch}

        true ->
          fetch_payment_attempt(booking.uuid, reference)
      end
    end
  end

  defp fetch_payment_attempt(booking_id, reference) do
    case Repo.query(
           """
           SELECT id, reference, status, amount_minor, currency
           FROM public.payment_attempts
           WHERE booking_id = $1
             AND reference = $2
             AND status IN ('initializing', 'ready', 'paid')
           LIMIT 1
           """,
           [booking_id, reference]
         ) do
      {:ok, %{rows: [[attempt_id, stored_reference, status, amount_minor, currency]]}} ->
        {:ok,
         %{
           attempt_id: attempt_id,
           reference: stored_reference,
           state: status,
           amount_minor: amount_to_integer(amount_minor),
           currency: normalize_currency(currency)
         }}

      {:ok, %{rows: []}} ->
        {:error, :payment_reference_mismatch}

      {:error, error} ->
        database_error(error)
    end
  end

  defp requested_reference(params) do
    case params["reference"] do
      value when is_binary(value) -> normalized_reference(value)
      _ -> nil
    end
  end

  defp normalized_reference(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      reference -> reference
    end
  end

  defp normalized_reference(_), do: nil

  defp provider_status(receipt) do
    case receipt[:status] || receipt["status"] do
      status when is_binary(status) -> String.downcase(status)
      _ -> nil
    end
  end

  defp verify_receipt(attempt, receipt) do
    status = provider_status(receipt)
    receipt_reference = normalized_reference(receipt[:reference] || receipt["reference"])

    cond do
      receipt_reference != attempt.reference ->
        {:error, :payment_reference_mismatch}

      status in @terminal_provider_statuses ->
        if fail_attempt(
             attempt.attempt_id,
             "Paystack transaction #{status} during verification"
           ) do
          {:error, :payment_failed}
        else
          {:error, :database_unavailable}
        end

      true ->
        assert_successful_payment(attempt, receipt)
    end
  end

  defp assert_successful_payment(source, receipt) do
    amount = amount_to_integer(receipt[:amount] || receipt["amount"])
    currency = receipt[:currency] || receipt["currency"]
    status = provider_status(receipt)
    receipt_reference = normalized_reference(receipt[:reference] || receipt["reference"])

    cond do
      receipt_reference != source.reference ->
        {:error, :payment_reference_mismatch}

      status != "success" ->
        {:error, :payment_incomplete}

      amount != source.amount_minor ->
        {:error, :amount_mismatch}

      not is_binary(currency) or String.upcase(currency) != String.upcase(source.currency) ->
        {:error, :amount_mismatch}

      true ->
        :ok
    end
  end

  defp mark_paid(booking_id, attempt) do
    Repo.transaction(fn ->
      with {:ok, %{rows: [[payment_status, booking_reference]]}} <-
             Repo.query(
               "SELECT payment_status, reference FROM public.bookings WHERE id = $1 FOR UPDATE",
               [booking_id]
             ),
           :ok <- assert_booking_reference(payment_status, booking_reference, attempt.reference),
           {:ok, %{rows: [[_attempt_id]]}} <-
             Repo.query(
               """
               UPDATE public.payment_attempts
               SET status = 'paid',
                   paid_at = coalesce(paid_at, now()),
                   updated_at = now()
               WHERE booking_id = $1
                 AND reference = $2
                 AND status IN ('initializing', 'ready', 'paid')
               RETURNING id
               """,
               [booking_id, attempt.reference]
             ),
           {:ok, %{rows: [[_booking_id]]}} <-
             Repo.query(
               """
               UPDATE public.bookings
               SET payment_status = 'paid',
                   payment_method = 'paystack',
                   updated_at = now()
               WHERE id = $1
                 AND reference = $2
               RETURNING id
               """,
               [booking_id, attempt.reference]
             ) do
        :ok
      else
        {:ok, %{rows: []}} -> Repo.rollback(:payment_reference_mismatch)
        {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp assert_booking_reference(payment_status, booking_reference, reference) do
    cond do
      paid?(payment_status) and normalized_reference(booking_reference) == reference ->
        :ok

      paid?(payment_status) ->
        {:error, :already_paid}

      normalized_reference(booking_reference) != reference ->
        {:error, :payment_reference_mismatch}

      true ->
        :ok
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

  defp poll_delays_ms do
    Application.get_env(:mithril, :direct_payment_poll_delays_ms, @default_poll_delays_ms)
  end

  defp paid?(status) when is_binary(status) do
    String.downcase(status) in ~w(paid post_paid refunded partially_refunded)
  end

  defp paid?(_), do: false

  defp normalize_currency(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "GHS"
      currency -> String.upcase(currency)
    end
  end

  defp normalize_currency(_), do: "GHS"

  defp amount_to_integer(value) when is_integer(value), do: value
  defp amount_to_integer(%Decimal{} = value), do: Decimal.to_integer(value)

  defp amount_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp amount_to_integer(_), do: 0

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(%Decimal{} = value), do: Decimal.to_integer(value)

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_or_nil(_), do: nil

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_value), do: :error

  defp database_error(error) do
    Logger.error("Direct payments database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
