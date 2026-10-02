defmodule Mithril.StripeBookingPayments do
  @moduledoc false

  require Logger

  alias Mithril.Repo
  alias Mithril.Stripe
  alias Mithril.StripeChargeCurrency
  alias Mithril.StripeCheckout

  @poll_delays_ms [100, 150, 200, 250, 300, 400]
  @settled_statuses ~w(paid post_paid refunded partially_refunded)

  @spec options(String.t(), map()) :: {:ok, map()}
  def options(user_id, body) when is_binary(user_id) and is_map(body) do
    client_platform =
      optional_string(body, "client_platform") || optional_string(body, "clientPlatform")

    result =
      with {:ok, booking_id} <- required_uuid(body, "booking_id"),
           {:ok, customer_id} <- dump_uuid(user_id),
           {:ok, booking_uuid} <- dump_uuid(booking_id),
           {:ok, booking_meta} <- load_booking_meta(customer_id, booking_uuid),
           {:ok, :payable} <- ensure_not_settled(booking_meta.payment_status),
           {:ok, snapshot} <- payable_snapshot(user_id, booking_uuid, booking_meta.specialty_slug),
           {:ok, subscription_activatable} <- subscription_gate(customer_id, booking_meta) do
        StripeCheckout.availability(
          client_platform: client_platform,
          subscription_activatable: subscription_activatable,
          amount_minor: snapshot.amount_minor
        )
      else
        _ -> %{stripe_available: false, reason: "booking_unavailable"}
      end

    {:ok,
     %{
       paystack_available: true,
       stripe_available: result.stripe_available,
       stripe_unavailable_reason: result.reason
     }}
  end

  @spec initialize(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def initialize(user_id, body) when is_binary(user_id) and is_map(body) do
    with :ok <- ensure_stripe_configured(),
         :ok <- ensure_checkout_enabled(),
         {:ok, booking_id} <- required_uuid(body, "booking_id"),
         {:ok, customer_id} <- dump_uuid(user_id),
         {:ok, booking_uuid} <- dump_uuid(booking_id),
         client_platform <- optional_string(body, "client_platform"),
         {:ok, email} <- authorized_checkout_email(customer_id, user_id, body),
         {:ok, booking_meta} <- load_booking_meta(customer_id, booking_uuid),
         {:ok, :payable} <- ensure_not_settled(booking_meta.payment_status),
         {:ok, snapshot} <- payable_snapshot(user_id, booking_uuid, booking_meta.specialty_slug),
         {:ok, subscription_activatable} <- subscription_gate(customer_id, booking_meta),
         :ok <-
           ensure_stripe_available(client_platform, subscription_activatable, snapshot.amount_minor),
         {:ok, response} <-
           prepare_checkout(user_id, booking_id, booking_uuid, snapshot, booking_meta, email) do
      {:ok, response}
    else
      {:error, {:status, _, _} = error} -> {:error, error}
      {:error, :not_found} -> {:error, {:status, 404, %{error: "Booking is not payable"}}}
      {:error, reason} when is_atom(reason) -> {:error, map_atom_error(reason)}
    end
  end

  defp ensure_stripe_configured do
    if Stripe.configured?(), do: :ok, else: {:error, {:status, 503, %{error: "Stripe checkout is not available"}}}
  end

  defp ensure_checkout_enabled do
    if StripeCheckout.checkout_enabled?(),
      do: :ok,
      else: {:error, {:status, 503, %{error: "Stripe checkout is not available"}}}
  end

  defp ensure_stripe_available(client_platform, subscription_activatable, amount_minor) do
    case StripeCheckout.availability(
           client_platform: client_platform,
           subscription_activatable: subscription_activatable,
           amount_minor: amount_minor
         ) do
      %{stripe_available: true} ->
        :ok

      %{reason: "recurring_paystack_only"} ->
        {:error,
         {:status, 409,
          %{
            error: "Recurring bookings must be paid with Paystack so later visits can be billed.",
            reason: "recurring_paystack_only"
          }}}

      _ ->
        {:error, {:status, 409, %{error: "Stripe checkout is not available for this booking."}}}
    end
  end

  defp prepare_checkout(user_id, booking_id, booking_uuid, snapshot, booking_meta, email) do
    fingerprint =
      request_fingerprint(
        booking_id,
        snapshot.amount_minor,
        snapshot.currency,
        booking_meta.cleaner_id,
        booking_meta.subscription_id,
        booking_meta.specialty_slug
      )

    with {:ok, attempt} <- reserve_stripe_attempt(booking_uuid, fingerprint, snapshot),
         :ok <- cancel_superseded_intents(booking_uuid),
         {:ok, result} <- normalize_attempt(attempt, booking_uuid, fingerprint, snapshot) do
      cond do
        Map.get(result, :already_settled) == true ->
          {:ok, result}

        Map.get(result, :payment_intent_id) ->
          {:ok, result}

        true ->
          case ready_usd_checkout(result) do
            {:ok, payload} -> {:ok, payload}
            :retry -> do_create_intent(user_id, booking_id, result, snapshot, booking_meta, email)
          end
      end
    else
      {:error, :conflict} ->
        {:error,
         {:status, 409,
          %{
            error:
              "This booking changed after payment checkout was prepared. Start a new booking before paying."
          }}}

      {:error, :missing_attempt} ->
        {:error, {:status, 404, %{error: "Booking is not payable"}}}

      {:error, {:cancel_failed, _reason}} ->
        {:error,
         {:status, 502,
          %{error: "Could not safely replace the previous card checkout. Please try again."}}}

      {:error, reason} when is_atom(reason) ->
        {:error, map_atom_error(reason)}
    end
  end

  defp normalize_attempt(%{state: "settled"} = attempt, _booking_uuid, _fingerprint, _snapshot) do
    {:ok,
     %{
       already_settled: true,
       payment_status: attempt.payment_status || "paid",
       reference: attempt.reference
     }}
  end

  defp normalize_attempt(%{state: "conflict"}, _booking_uuid, _fingerprint, _snapshot) do
    {:error,
     {:status, 409,
      %{
        error:
          "This booking changed after payment checkout was prepared. Start a new booking before paying."
      }}}
  end

  defp normalize_attempt(%{state: "ready"} = attempt, booking_uuid, fingerprint, snapshot) do
    case ready_usd_checkout(attempt) do
      {:ok, payload} ->
        {:ok, payload}

      :retry ->
        if fail_attempt(
             attempt.attempt_id,
             "Stripe checkout was ready without a usable USD PaymentIntent"
           ) do
          with {:ok, replacement} <- reserve_stripe_attempt(booking_uuid, fingerprint, snapshot) do
            normalize_attempt(replacement, booking_uuid, fingerprint, snapshot)
          end
        else
          {:error, :prepare_failed}
        end
    end
  end

  defp normalize_attempt(%{state: "initializing", created: false} = attempt, booking_uuid, fingerprint, snapshot) do
    polled =
      Enum.reduce(@poll_delays_ms, attempt, fn delay_ms, current ->
        if delay_ms > 0, do: Process.sleep(delay_ms)

        case reserve_stripe_attempt(booking_uuid, fingerprint, snapshot) do
          {:ok, next} ->
            case ready_usd_checkout(next) do
              {:ok, _payload} -> next
              :retry when next.created or next.state != "initializing" -> next
              :retry -> current
            end

          {:error, _} ->
            current
        end
      end)

    {:ok, polled}
  end

  defp normalize_attempt(attempt, _booking_uuid, _fingerprint, _snapshot), do: {:ok, attempt}

  defp do_create_intent(user_id, booking_id, attempt, snapshot, booking_meta, email) do
    cond do
      is_nil(attempt.attempt_id) or is_nil(attempt.reference) ->
        {:error, :prepare_failed}

      true ->
        with {:ok, fx} <- StripeChargeCurrency.fetch_ghs_to_usd_rate(),
             {:ok, charge} <-
               StripeChargeCurrency.presentment_charge(%{
                 booking_amount_minor: snapshot.amount_minor,
                 booking_currency: snapshot.currency,
                 usd_per_ghs: fx.usd_per_ghs
               }),
             {:ok, provider} <-
               Stripe.create_payment_intent(%{
                 reference: attempt.reference,
                 form_params: payment_intent_form(
                   charge,
                   fx,
                   booking_id,
                   user_id,
                   attempt.reference,
                   email,
                   booking_meta,
                   snapshot
                 )
               }),
             {:ok, completed} <-
               complete_stripe_attempt(
                 attempt.attempt_id,
                 provider.id,
                 provider.client_secret,
                 attempt.reference
               ) do
          case completed do
            %{already_settled: true} = settled ->
              {:ok, settled}

            _ ->
              {:ok,
               %{
                 payment_intent_id: provider.id,
                 client_secret: provider.client_secret,
                 reference: attempt.reference,
                 amount_minor: charge.amount_minor,
                 currency: charge.currency
               }}
          end
        else
          {:error, :prepare_failed} ->
            {:error, {:status, 502, %{error: "Failed to prepare Stripe checkout"}}}

          {:error, {:provider, status, message}} ->
            _ = fail_attempt(attempt.attempt_id, "Stripe #{status}: #{message}")

            {:error,
             {:status, 502,
              %{
                error: StripeChargeCurrency.user_facing_init_error(message)
              }}}

          {:error, message} when is_binary(message) ->
            {:error, {:status, 400, %{error: message}}}

          {:error, _} ->
            {:error,
             {:status, 502,
              %{
                error:
                  "Card checkout is not available right now. Please pay with Mobile Money or try again."
              }}}
        end
    end
  end

  defp payment_intent_form(charge, fx, booking_id, user_id, reference, email, booking_meta, snapshot) do
    metadata =
      %{
        "booking_id" => booking_id,
        "customer_id" => user_id,
        "reference" => reference,
        "funds_destination" => "instaclean_inc",
        "charge_split" => "platform_collected",
        "booking_amount_minor" => Integer.to_string(charge.source_amount_minor),
        "booking_currency" => charge.source_currency,
        "stripe_charge_amount_minor" => Integer.to_string(charge.amount_minor),
        "stripe_charge_currency" => charge.currency,
        "usd_per_ghs" => Float.to_string(fx.usd_per_ghs),
        "fx_rate_source" => fx.source
      }
      |> maybe_put_metadata("fx_quote_id", fx.quote_id)
      |> maybe_put_metadata("cleaner_id", booking_meta.cleaner_id)
      |> maybe_put_metadata("tax_share_minor", share_minor(snapshot.tax_share_minor))
      |> maybe_put_metadata("vendor_share_minor", share_minor(snapshot.vendor_share_minor))
      |> maybe_put_metadata("platform_share_minor", share_minor(snapshot.platform_share_minor))

    %{
      amount: charge.amount_minor,
      currency: charge.currency,
      automatic_payment_methods: %{enabled: "true"},
      receipt_email: email,
      description: "Instaclean booking",
      metadata: metadata
    }
  end

  defp ready_usd_checkout(%{stripe_payment_intent_id: pi, stripe_client_secret: secret} = attempt)
       when is_binary(pi) and pi != "" and is_binary(secret) and secret != "" do
    case Stripe.fetch_payment_intent(pi) do
      {:ok, %{amount: amount, currency: currency, status: status}}
      when currency in ["usd", "USD"] and
             status in ["requires_payment_method", "requires_confirmation", "requires_action"] ->
        amount_minor = amount_to_integer(amount)

        if amount_minor > 0 do
          {:ok,
           %{
             payment_intent_id: pi,
             client_secret: secret,
             reference: attempt.reference,
             amount_minor: amount_minor,
             currency: "usd"
           }}
        else
          :retry
        end

      _ ->
        :retry
    end
  end

  defp ready_usd_checkout(_), do: :retry

  defp reserve_stripe_attempt(booking_uuid, fingerprint, snapshot) do
    case Repo.query(
           """
           SELECT attempt_id, created, state, reference, authorization_url, access_code,
                  payment_status, expires_at, amount_minor, currency, request_fingerprint,
                  provider, stripe_payment_intent_id, stripe_client_secret
           FROM public.reserve_booking_payment_attempt($1::uuid, $2::text, $3::bigint, $4::text, 'stripe')
           """,
           [booking_uuid, fingerprint, snapshot.amount_minor, snapshot.currency]
         ) do
      {:ok, %{rows: [row]}} ->
        case attempt_from_row(row) do
          {:ok, attempt} -> {:ok, attempt}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{rows: []}} ->
        {:error, :missing_attempt}

      {:error, error} ->
        Logger.error("Stripe reserve attempt failed: #{inspect(error)}")
        {:error, :prepare_failed}
    end
  end

  defp complete_stripe_attempt(attempt_id, payment_intent_id, client_secret, reference) do
    case Repo.query(
           """
           SELECT state, reference, stripe_payment_intent_id, stripe_client_secret, payment_status
           FROM public.complete_stripe_booking_payment_attempt($1::uuid, $2::text, $3::text, $4::text)
           """,
           [attempt_id, payment_intent_id, client_secret, reference]
         ) do
      {:ok, %{rows: [["settled", ref, _pi, _secret, payment_status | _]]}} ->
        {:ok,
         %{
           already_settled: true,
           payment_status: payment_status || "paid",
           reference: ref
         }}

      {:ok, %{rows: [_row]}} ->
        {:ok, %{}}

      {:error, error} ->
        Logger.error("Stripe complete attempt failed: #{inspect(error)}")
        {:error, :prepare_failed}
    end
  end

  defp attempt_from_row(row) do
    [
      attempt_id,
      created,
      state,
      reference,
      _authorization_url,
      _access_code,
      payment_status,
      _expires_at,
      amount_minor,
      currency,
      _request_fingerprint,
      _provider,
      stripe_payment_intent_id,
      stripe_client_secret
    ] = row

    state = to_string(state || "")

    cond do
      state == "settled" ->
        {:ok,
         %{
           state: "settled",
           payment_status: payment_status,
           reference: reference
         }}

      state == "conflict" ->
        {:error, :conflict}

      true ->
        {:ok,
         %{
           attempt_id: attempt_id,
           created: created == true,
           state: state,
           reference: reference,
           amount_minor: amount_to_integer(amount_minor),
           currency: normalize_currency(currency),
           stripe_payment_intent_id: stripe_payment_intent_id,
           stripe_client_secret: stripe_client_secret
         }}
    end
  end

  defp cancel_superseded_intents(booking_uuid) do
    case Repo.query(
           """
           SELECT stripe_payment_intent_id
           FROM public.payment_attempts
           WHERE booking_id = $1
             AND provider = 'stripe'
             AND status = 'superseded'
             AND stripe_payment_intent_id IS NOT NULL
           """,
           [booking_uuid]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.reduce_while(rows, :ok, fn [payment_intent_id], :ok ->
          cond do
            not is_binary(payment_intent_id) or payment_intent_id == "" ->
              {:cont, :ok}

            true ->
              case Stripe.cancel_payment_intent(payment_intent_id) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, {:cancel_failed, reason}}}
              end
          end
        end)

      {:error, error} ->
        Logger.error("Stripe superseded intent lookup failed: #{inspect(error)}")
        {:error, :database_unavailable}
    end
  end

  defp fail_attempt(attempt_id, reason) do
    case Repo.query(
           "SELECT public.fail_booking_payment_attempt($1::uuid, $2::text)",
           [attempt_id, reason]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp payable_snapshot(user_id, booking_uuid, specialty_slug) do
    function_name =
      if specialty_slug == "airbnb_turnover" do
        "authorize_airbnb_turnover_payment"
      else
        "get_payable_booking_snapshot"
      end

    query = """
    SELECT booking_id, customer_id, final_amount_minor, currency, payment_status,
           booking_status, payment_reference, payment_split_type, paystack_split_code,
           tax_share_minor, vendor_share_minor, platform_share_minor
    FROM public.#{function_name}($1::uuid)
    """

    Repo.transaction(fn ->
      with {:ok, _} <-
             Repo.query("SELECT set_config('request.jwt.claim.sub', $1::text, true)", [user_id]),
           {:ok, result} <- Repo.query(query, [booking_uuid]) do
        case result.rows do
          [
            [
              _id,
              _customer_id,
              amount_minor,
              currency,
              _payment_status,
              _booking_status,
              _payment_reference,
              _payment_split_type,
              _paystack_split_code,
              tax_share_minor,
              vendor_share_minor,
              platform_share_minor
            ]
          ] ->
            amount = amount_to_integer(amount_minor)

            if amount > 0 do
              %{
                amount_minor: amount,
                currency: normalize_currency(currency),
                tax_share_minor: tax_share_minor,
                vendor_share_minor: vendor_share_minor,
                platform_share_minor: platform_share_minor
              }
            else
              Repo.rollback(:not_payable)
            end

          [] ->
            Repo.rollback(:not_found)
        end
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, error} ->
        Logger.error("Stripe payable snapshot failed: #{inspect(error)}")
        {:error, :snapshot_failed}
    end
  end

  defp load_booking_meta(customer_id, booking_uuid) do
    case Repo.query(
           """
           SELECT b.cleaner_id::text, b.subscription_id::text, b.payment_status, st.specialty_slug
           FROM public.bookings b
           JOIN public.service_types st ON st.id = b.service_id
           WHERE b.id = $1 AND b.customer_id = $2
           LIMIT 1
           """,
           [booking_uuid, customer_id]
         ) do
      {:ok, %{rows: [[cleaner_id, subscription_id, payment_status, specialty_slug]]}} ->
        {:ok,
         %{
           cleaner_id: blank_to_nil(cleaner_id),
           subscription_id: blank_to_nil(subscription_id),
           payment_status: payment_status,
           specialty_slug: specialty_slug
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        Logger.error("Stripe booking meta failed: #{inspect(error)}")
        {:error, :database_unavailable}
    end
  end

  defp subscription_gate(_customer_id, %{subscription_id: nil}), do: {:ok, false}

  defp subscription_gate(customer_id, %{subscription_id: subscription_id}) do
    case Repo.query(
           """
           SELECT status, recurrence_interval
           FROM public.subscriptions
           WHERE id = $1::uuid AND customer_id = $2::uuid
           LIMIT 1
           """,
           [subscription_id, customer_id]
         ) do
      {:ok, %{rows: [[status, recurrence_interval]]}} ->
        case classify_subscription(status, recurrence_interval) do
          {:ok, activatable} -> {:ok, activatable}
          {:error, message} -> {:error, {:status, 400, %{error: message}}}
        end

      {:ok, %{rows: []}} ->
        {:error, {:status, 404, %{error: "The linked subscription could not be found."}}}

      {:error, _} ->
        {:error,
         {:status, 500, %{error: "We could not verify this subscription. Please try again."}}}
    end
  end

  defp classify_subscription(status, recurrence_interval) do
    normalized = status |> to_string() |> String.downcase()

    cond do
      normalized in ~w(pending active) ->
        if valid_recurrence?(recurrence_interval) do
          {:ok, true}
        else
          {:error, "This subscription has an invalid billing schedule. Please contact support."}
        end

      normalized in ~w(cancelled completed) ->
        {:ok, false}

      true ->
        {:error, "We could not verify this subscription. Please try again."}
    end
  end

  defp valid_recurrence?(interval) when is_binary(interval) do
    interval
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ~w(hourly daily weekly bi-weekly monthly quarterly annually)))
  end

  defp valid_recurrence?(_), do: false

  defp ensure_not_settled(payment_status) do
    normalized = payment_status |> to_string() |> String.downcase()

    if normalized in @settled_statuses do
      {:error,
       {:status, 409,
        %{
          error: "Booking payment is already settled.",
          reason: "already_settled",
          payment_status: normalized
        }}}
    else
      {:ok, :payable}
    end
  end

  defp authorized_checkout_email(customer_id, user_id, body) do
    with {:ok, account_email} <- load_account_email(customer_id, user_id),
         :ok <- validate_body_email(body, account_email) do
      {:ok, account_email}
    end
  end

  defp load_account_email(customer_id, _user_id) do
    case Repo.query("SELECT email FROM public.users WHERE id = $1::uuid LIMIT 1", [customer_id]) do
      {:ok, %{rows: [[email]]}} ->
        resolved = resolve_account_email(email)

        if resolved do
          {:ok, resolved}
        else
          {:error, {:status, 400, %{error: "Missing or invalid email. Add an email to your account before paying."}}}
        end

      {:ok, _} ->
        {:error, {:status, 400, %{error: "Missing or invalid email. Add an email to your account before paying."}}}

      {:error, _} ->
        {:error, {:status, 502, %{error: "Failed to load account email"}}}
    end
  end

  defp validate_body_email(body, account_email) do
    case optional_string(body, "email") do
      nil ->
        :ok

      body_email ->
        if String.downcase(body_email) == String.downcase(account_email) do
          :ok
        else
          {:error, {:status, 400, %{error: "Email does not match your account"}}}
        end
    end
  end

  defp resolve_account_email(email) when is_binary(email) do
    trimmed = String.trim(email)

    cond do
      trimmed == "" -> nil
      String.ends_with?(String.downcase(trimmed), "@phone.tryinstaclean.local") -> nil
      true -> trimmed
    end
  end

  defp resolve_account_email(_), do: nil

  defp request_fingerprint(
         booking_id,
         amount_minor,
         currency,
         cleaner_id,
         subscription_id,
         specialty_slug
       ) do
    payload =
      Jason.encode!(%{
        provider: "stripe",
        booking_id: booking_id,
        amount_minor: amount_minor,
        currency: currency,
        cleaner_id: cleaner_id,
        subscription_id: subscription_id,
        specialty_slug: specialty_slug
      })

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp required_uuid(body, key) do
    case Map.get(body, key) || Map.get(body, camel_key(key)) do
      value when is_binary(value) and value != "" ->
        case Ecto.UUID.cast(String.trim(value)) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, :bad_request}
        end

      _ ->
        {:error, {:status, 400, %{error: "Missing or invalid booking_id"}}}
    end
  end

  defp camel_key("booking_id"), do: "bookingId"

  defp optional_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp share_minor(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp share_minor(%Decimal{} = value), do: value |> Decimal.to_integer() |> Integer.to_string()
  defp share_minor(_), do: nil

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, ""), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp blank_to_nil(_), do: nil

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

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)

  defp map_atom_error(:bad_request), do: {:status, 400, %{error: "Invalid request"}}
  defp map_atom_error(:not_payable), do: {:status, 400, %{error: "Booking has no payable amount"}}
  defp map_atom_error(:snapshot_failed), do: {:status, 502, %{error: "Failed to load payable booking snapshot"}}
  defp map_atom_error(:prepare_failed), do: {:status, 502, %{error: "Failed to prepare Stripe checkout"}}
  defp map_atom_error(:database_unavailable), do: {:status, 502, %{error: "Failed to prepare Stripe checkout"}}
  defp map_atom_error(reason), do: {:status, 500, %{error: Atom.to_string(reason)}}
end
