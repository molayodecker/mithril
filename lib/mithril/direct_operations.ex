defmodule Mithril.DirectOperations do
  @moduledoc """
  Auditable customer and admin operations used by Instaclean agents.

  Financial execution stays outside agent-facing flows: refund tools create
  reviewable requests, while cancellation computes the policy-derived amount.
  """

  require Logger

  alias Mithril.Paystack
  alias Mithril.Repo

  @cancellable_statuses ~w(pending confirmed scheduled)
  @reschedulable_statuses ~w(confirmed scheduled)
  @default_timezone "Africa/Accra"

  def cancellation_policy(user_id, booking_id) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, booking} <- fetch_booking_for_actor(actor_uid, bid, false) do
      {:ok, cancellation_payload(booking)}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_booking(user_id, booking_id, params) when is_map(params) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id) do
      Repo.transaction(fn ->
        booking = fetch_booking_for_actor!(actor_uid, bid)

        cond do
          booking.status == "cancelled" ->
            Map.merge(cancellation_payload(booking), %{alreadyCancelled: true})

          booking.subscription_id != nil ->
            Repo.rollback(:recurring_booking_requires_manual_review)

          booking.status not in @cancellable_statuses ->
            Repo.rollback(:booking_not_cancellable)

          true ->
            cancel_open_booking(booking, actor_uid, params)
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def request_refund(user_id, booking_id, params) when is_map(params) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, reason} <- required_text(params["reason"], 3, 2_000) do
      Repo.transaction(fn ->
        booking = fetch_booking_for_actor!(actor_uid, bid)

        cond do
          booking.payment_status == "refunded" ->
            Repo.rollback(:already_refunded)

          booking.payment_status not in ~w(paid partially_refunded) ->
            Repo.rollback(:payment_not_refundable)

          true ->
            policy = cancellation_payload(booking)

            ensure_refund_request!(
              booking,
              actor_uid,
              reason,
              booking.cancellation_tier || eligible_policy_tier(booking, policy),
              eligible_refund_percent(booking, policy),
              eligible_refund_amount(booking, policy)
            )
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def reschedule_booking(user_id, booking_id, params) when is_map(params) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, scheduled_date} <- iso_date(params["scheduledDate"]),
         {:ok, scheduled_time} <- iso_time(params["scheduledTime"]) do
      Repo.transaction(fn ->
        booking = fetch_booking_for_actor!(actor_uid, bid)

        cond do
          booking.subscription_id != nil ->
            Repo.rollback(:recurring_booking_requires_manual_review)

          booking.payment_status != "paid" ->
            Repo.rollback(:booking_not_reschedulable)

          booking.status not in @reschedulable_statuses ->
            Repo.rollback(:booking_not_reschedulable)

          true ->
            reschedule_paid_booking(booking, scheduled_date, scheduled_time, params)
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
    end
  end

  def list_cleaners(user_id, params) when is_map(params) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         :ok <- require_admin(actor_uid),
         {:ok, search} <- optional_search(params["q"]),
         {:ok, status} <- optional_status(params["status"]),
         {:ok, verified} <- optional_boolean(params["verified"]),
         {:ok, limit} <- optional_limit(params["limit"]) do
      like = if search == "", do: nil, else: "%#{String.downcase(search)}%"

      case Repo.query(
             """
             SELECT jsonb_build_object(
               'userId', cd.user_id,
               'name', COALESCE(
                 NULLIF(btrim(p.fullname), ''),
                 NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
                 u.email,
                 u.phone,
                 'Instaclean professional'
               ),
               'email', u.email,
               'phone', u.phone,
               'status', cd.status,
               'verified', cd.verified,
               'rating', cd.rating,
               'completedJobs', cd.completed_jobs,
               'hourlyRateGhs', cd.hourly_rate,
               'specialties', COALESCE(cd.specialties, ARRAY[]::text[]),
               'applicationId', app.id,
               'applicationStatus', app.status,
               'updatedAt', cd.updated_at
             )
             FROM public.cleaner_data cd
             JOIN public.users u ON u.id = cd.user_id
             LEFT JOIN public.profiles p ON p.id = cd.user_id
             LEFT JOIN LATERAL (
               SELECT ca.id, ca.status
               FROM public.cleaner_applications ca
               WHERE ca.user_id = cd.user_id
               ORDER BY ca.created_at DESC
               LIMIT 1
             ) app ON true
             WHERE ($1::text IS NULL OR (
                    lower(COALESCE(u.email, '')) LIKE $1
                 OR lower(COALESCE(u.phone, '')) LIKE $1
                 OR lower(COALESCE(p.fullname, '')) LIKE $1
                 OR lower(COALESCE(p.firstname, '') || ' ' || COALESCE(p.lastname, '')) LIKE $1
             ))
               AND ($2::text IS NULL OR cd.status::text = $2)
               AND ($3::boolean IS NULL OR cd.verified = $3)
             ORDER BY cd.verified DESC, COALESCE(cd.rating, 0) DESC, cd.updated_at DESC
             LIMIT $4
             """,
             [like, status, verified, limit]
           ) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_cleaner_applications(user_id, params) when is_map(params) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         :ok <- require_admin(actor_uid),
         {:ok, search} <- optional_search(params["q"]),
         {:ok, status} <- optional_application_status(params["status"]),
         {:ok, limit} <- optional_limit(params["limit"]) do
      like = if search == "", do: nil, else: "%#{String.downcase(search)}%"

      case Repo.query(
             """
             SELECT jsonb_build_object(
               'id', ca.id,
               'userId', ca.user_id,
               'name', ca.name,
               'email', ca.email,
               'phone', ca.phone,
               'status', ca.status,
               'hourlyRateGhs', ca.hourly_rate,
               'createdAt', ca.created_at,
               'updatedAt', ca.updated_at
             )
             FROM public.cleaner_applications ca
             WHERE ($1::text IS NULL OR (
                    lower(COALESCE(ca.name, '')) LIKE $1
                 OR lower(COALESCE(ca.email, '')) LIKE $1
                 OR lower(COALESCE(ca.phone, '')) LIKE $1
             ))
               AND ($2::text IS NULL OR ca.status::text = $2)
             ORDER BY ca.created_at DESC
             LIMIT $3
             """,
             [like, status, limit]
           ) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def approve_cleaner_application(user_id, application_id) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         {:ok, app_id} <- dump_uuid(application_id),
         :ok <- require_admin(actor_uid) do
      case Repo.query("SELECT public.approve_cleaner_application($1::uuid)", [app_id]) do
        {:ok, %{rows: [[result]]}} ->
          {:ok, result}

        {:ok, %{rows: []}} ->
          {:error, :application_not_found}

        {:error, %Postgrex.Error{postgres: postgres} = error} ->
          approval_error(postgres, error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def payment_diagnostics(user_id, booking_id) do
    with {:ok, actor_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(actor_uid),
         {:ok, booking} <- fetch_payment_booking(bid),
         {:ok, attempts} <- fetch_payment_attempts(bid) do
      latest = List.first(attempts)
      reference = latest_reference(latest, booking.reference)
      provider = provider_diagnostics(reference)

      {:ok,
       %{
         bookingId: booking.id,
         bookingStatus: booking.status,
         paymentStatus: booking.payment_status,
         bookingReference: booking.reference,
         amountMinor: booking.amount_minor,
         currency: booking.currency,
         attempts: attempts,
         provider: provider,
         likelyReason: likely_payment_reason(latest, provider, booking.payment_status)
       }}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_open_booking(booking, actor_uid, params) do
    policy = cancellation_payload(booking)
    reason = optional_text(params["reason"], 500)
    role = if booking.actor_is_admin, do: "admin", else: "customer"

    case Repo.query(
           """
           UPDATE public.bookings
           SET status = 'cancelled',
               cancelled_at = now(),
               cancelled_by = $2,
               cancelled_by_role = $3,
               cancellation_tier = $4,
               cancellation_reason = NULLIF($5::text, ''),
               cancellation_reason_code = $6,
               updated_at = now()
           WHERE id = $1
             AND status::text IN ('pending', 'confirmed', 'scheduled')
           RETURNING id::text
           """,
           [
             booking.uuid,
             actor_uid,
             role,
             policy.refundTier,
             reason,
             if(role == "admin", do: "admin_cancelled", else: "customer_cancelled")
           ]
         ) do
      {:ok, %{rows: [[id]]}} ->
        refund_request =
          maybe_queue_cancellation_refund(booking, actor_uid, reason, policy)

        Map.merge(policy, %{
          id: id,
          status: "cancelled",
          alreadyCancelled: false,
          refundRequest: refund_request
        })

      {:ok, %{rows: []}} ->
        Repo.rollback(:booking_not_cancellable)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp maybe_queue_cancellation_refund(booking, actor_uid, reason, policy) do
    if policy.refundAmountMinor > 0 do
      ensure_refund_request!(
        booking,
        actor_uid,
        reason_or_default(reason, "Cancellation refund review"),
        policy.refundTier,
        policy.refundPercent,
        policy.refundAmountMinor
      )
    end
  end

  defp reschedule_paid_booking(booking, scheduled_date, scheduled_time, params) do
    timezone =
      normalize_timezone(
        params["timezone"] || booking.timezone_name || booking.timezone ||
          @default_timezone
      )

    :ok =
      validate_timeslot(scheduled_date, scheduled_time, booking.duration_hours, timezone)

    :ok = validate_cleaner_availability(booking, scheduled_date, scheduled_time, timezone)

    case Repo.query(
           """
           UPDATE public.bookings
           SET scheduled_date = $2::date,
               scheduled_time = $3::time,
               timezone = $4,
               timezone_name = $4,
               customer_reminder_sent_at = NULL,
               customer_reminder_48h_sent_at = NULL,
               customer_reminder_morning_sent_at = NULL,
               customer_reminder_claimed_at = NULL,
               customer_reminder_48h_claimed_at = NULL,
               customer_reminder_morning_claimed_at = NULL,
               cleaner_reminder_sent_at = NULL,
               cleaner_reminder_claimed_at = NULL,
               updated_at = now()
           WHERE id = $1
             AND payment_status = 'paid'
             AND status::text IN ('confirmed', 'scheduled')
             AND subscription_id IS NULL
           RETURNING id::text
           """,
           [booking.uuid, scheduled_date, scheduled_time, timezone]
         ) do
      {:ok, %{rows: [[id]]}} ->
        %{
          id: id,
          status: booking.status,
          oldScheduledDate: booking.scheduled_date,
          oldScheduledTime: booking.scheduled_time,
          scheduledDate: Date.to_iso8601(scheduled_date),
          scheduledTime: format_time(scheduled_time),
          timezone: timezone
        }

      {:ok, %{rows: []}} ->
        Repo.rollback(:booking_not_reschedulable)

      {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} ->
        Repo.rollback(:cleaner_unavailable)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp fetch_booking_for_actor!(actor_uid, bid) do
    case fetch_booking_for_actor(actor_uid, bid, true) do
      {:ok, booking} -> booking
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fetch_booking_for_actor(actor_uid, bid, lock?) do
    lock = if lock?, do: "FOR UPDATE", else: ""

    case Repo.query(
           """
           SELECT b.id::text,
                  b.customer_id::text,
                  b.status::text,
                  b.payment_status,
                  b.subscription_id::text,
                  b.cleaner_id,
                  b.service_id,
                  b.scheduled_date::text,
                  b.scheduled_time::text,
                  b.duration_hours,
                  b.timezone_name,
                  b.timezone,
                  COALESCE(b.final_amount_minor, b.total_price)::bigint,
                  COALESCE(b.currency, 'GHS'),
                  b.cancellation_tier,
                  COALESCE((
                    SELECT SUM(br.refund_amount_minor)::bigint
                    FROM public.booking_refunds br
                    WHERE br.booking_id = b.id
                      AND br.status = 'processed'
                  ), 0)::bigint AS refunded_amount_minor,
                  EXISTS (
                    SELECT 1
                    FROM public.user_roles ur
                    WHERE ur.user_id = $1 AND ur.role_id = 'admin'
                  ) AS actor_is_admin
           FROM public.bookings b
           WHERE b.id = $2
             AND (
               b.customer_id = $1
               OR EXISTS (
                 SELECT 1
                 FROM public.user_roles ur
                 WHERE ur.user_id = $1 AND ur.role_id = 'admin'
               )
             )
           LIMIT 1
           #{lock}
           """,
           [actor_uid, bid]
         ) do
      {:ok,
       %{
         rows: [
           [
             id,
             customer_id,
             status,
             payment_status,
             subscription_id,
             cleaner_id,
             service_id,
             scheduled_date,
             scheduled_time,
             duration_hours,
             timezone_name,
             timezone,
             amount_minor,
             currency,
             cancellation_tier,
             refunded_amount_minor,
             actor_is_admin
           ]
         ]
       }} ->
        {:ok,
         %{
           id: id,
           uuid: bid,
           customer_id: customer_id,
           status: status,
           payment_status: payment_status,
           subscription_id: subscription_id,
           cleaner_id: cleaner_id,
           service_id: service_id,
           scheduled_date: scheduled_date,
           scheduled_time: scheduled_time,
           duration_hours: duration_hours,
           timezone_name: timezone_name,
           timezone: timezone,
           amount_minor: integer_amount(amount_minor),
           currency: currency,
           cancellation_tier: cancellation_tier,
           refunded_amount_minor: integer_amount(refunded_amount_minor),
           actor_is_admin: actor_is_admin
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp cancellation_payload(booking) do
    tier = cancellation_tier(booking)
    can_cancel = booking.status in @cancellable_statuses and booking.subscription_id == nil
    refundable_payment = booking.payment_status in ~w(paid partially_refunded)

    refund_percent =
      cond do
        not refundable_payment -> 0
        tier == "full_refund" -> 100
        tier == "partial_refund" -> 50
        true -> 0
      end

    target_refund_amount_minor = round(booking.amount_minor * refund_percent / 100)

    refund_amount_minor =
      max(target_refund_amount_minor - booking.refunded_amount_minor, 0)

    %{
      id: booking.id,
      status: booking.status,
      paymentStatus: booking.payment_status,
      canCancel: can_cancel,
      refundTier: tier,
      refundPercent: refund_percent,
      refundAmountMinor: refund_amount_minor,
      alreadyRefundedAmountMinor: booking.refunded_amount_minor,
      currency: booking.currency,
      scheduledDate: booking.scheduled_date,
      scheduledTime: booking.scheduled_time,
      recurring: booking.subscription_id != nil
    }
  end

  defp cancellation_tier(%{cancellation_tier: tier})
       when tier in ~w(full_refund partial_refund no_refund),
       do: tier

  defp cancellation_tier(booking) do
    timezone = booking.timezone_name || booking.timezone || @default_timezone

    case Repo.query(
           """
           SELECT CASE
             WHEN $1::text::date = (now() AT TIME ZONE $3::text)::date
               OR (($1::text::date + $2::text::time) AT TIME ZONE $3::text) <= now()
               THEN 'no_refund'
             WHEN (($1::text::date + $2::text::time) AT TIME ZONE $3::text) - now() >= interval '24 hours'
               THEN 'full_refund'
             ELSE 'partial_refund'
           END
           """,
           [booking.scheduled_date, booking.scheduled_time, timezone]
         ) do
      {:ok, %{rows: [[tier]]}} -> tier
      _ -> "no_refund"
    end
  end

  defp ensure_refund_request!(booking, actor_uid, reason, tier, percent, amount_minor) do
    case Repo.query(
           """
           SELECT id::text, status
           FROM public.direct_refund_requests
           WHERE booking_id = $1
             AND status IN ('requested', 'reviewing', 'approved', 'processing')
           ORDER BY created_at DESC
           LIMIT 1
           """,
           [booking.uuid]
         ) do
      {:ok, %{rows: [[id, status]]}} ->
        %{id: id, status: status, existing: true}

      {:ok, %{rows: []}} ->
        insert_refund_request(booking, actor_uid, reason, tier, percent, amount_minor)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp insert_refund_request(booking, actor_uid, reason, tier, percent, amount_minor) do
    case Repo.query(
           """
           INSERT INTO public.direct_refund_requests (
             booking_id, customer_id, requested_by_user_id, status, reason,
             policy_tier, proposed_refund_percent, proposed_refund_amount_minor, source
           ) VALUES (
             $1, $2::text::uuid, $3, 'requested', $4, $5, $6, $7, 'mcp'
           )
           RETURNING id::text, status
           """,
           [booking.uuid, booking.customer_id, actor_uid, reason, tier, percent, amount_minor]
         ) do
      {:ok, %{rows: [[id, status]]}} ->
        %{id: id, status: status, existing: false}

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        existing_refund_request!(booking.uuid)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp existing_refund_request!(booking_id) do
    case Repo.query(
           """
           SELECT id::text, status
           FROM public.direct_refund_requests
           WHERE booking_id = $1
             AND status IN ('requested', 'reviewing', 'approved', 'processing')
           ORDER BY created_at DESC
           LIMIT 1
           """,
           [booking_id]
         ) do
      {:ok, %{rows: [[id, status]]}} -> %{id: id, status: status, existing: true}
      {:error, error} -> Repo.rollback({:database, error})
      _ -> Repo.rollback(:refund_request_conflict)
    end
  end

  defp validate_timeslot(date, time, duration_hours, timezone) do
    case Repo.query(
           """
           SELECT public.validate_booking_timeslot_24h(
             $1::text, $2::numeric, $3::date, $4::text
           )
           """,
           [format_time(time), duration_hours, date, timezone]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> Repo.rollback(:invalid_timeslot)
      {:error, error} -> Repo.rollback({:database, error})
    end
  end

  defp validate_cleaner_availability(%{cleaner_id: nil}, _date, _time, _timezone), do: :ok

  defp validate_cleaner_availability(booking, date, time, timezone) do
    case Repo.query(
           """
           SELECT
             EXISTS(
               SELECT 1
               FROM public.cleaner_availability_exceptions cae
               WHERE cae.cleaner_id = $1::uuid
                 AND cae.exception_date = $2::date
             ),
             public.cleaner_has_booking_conflict(
               $1::uuid,
               (($2::date + $3::time) AT TIME ZONE $5::text),
               (($2::date + $3::time) AT TIME ZONE $5::text)
                 + make_interval(secs => ($4::numeric * 3600)::double precision),
               $6::uuid
             )
           """,
           [booking.cleaner_id, date, time, booking.duration_hours, timezone, booking.uuid]
         ) do
      {:ok, %{rows: [[false, false]]}} -> :ok
      {:ok, %{rows: [[true, _]]}} -> Repo.rollback(:cleaner_unavailable)
      {:ok, %{rows: [[_, true]]}} -> Repo.rollback(:cleaner_unavailable)
      {:error, error} -> Repo.rollback({:database, error})
    end
  end

  defp fetch_payment_booking(bid) do
    case Repo.query(
           """
           SELECT b.id::text, b.status::text, b.payment_status, b.reference,
                  COALESCE(b.final_amount_minor, b.total_price)::bigint,
                  COALESCE(b.currency, 'GHS')
           FROM public.bookings b
           WHERE b.id = $1
           LIMIT 1
           """,
           [bid]
         ) do
      {:ok, %{rows: [[id, status, payment_status, reference, amount_minor, currency]]}} ->
        {:ok,
         %{
           id: id,
           status: status,
           payment_status: payment_status,
           reference: reference,
           amount_minor: integer_amount(amount_minor),
           currency: currency
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_payment_attempts(bid) do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'id', pa.id,
             'status', pa.status,
             'reference', pa.reference,
             'amountMinor', pa.amount_minor,
             'currency', pa.currency,
             'failureReason', pa.failure_reason,
             'createdAt', pa.created_at,
             'updatedAt', pa.updated_at,
             'readyAt', pa.ready_at,
             'paidAt', pa.paid_at,
             'failedAt', pa.failed_at
           )
           FROM public.payment_attempts pa
           WHERE pa.booking_id = $1
           ORDER BY pa.created_at DESC
           LIMIT 10
           """,
           [bid]
         ) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp provider_diagnostics(nil), do: %{status: "not_checked", reason: "no_reference"}

  defp provider_diagnostics(reference) do
    case Paystack.verify(reference) do
      {:ok, receipt} ->
        %{
          status: Map.get(receipt, :status) || Map.get(receipt, "status"),
          amountMinor: Map.get(receipt, :amount) || Map.get(receipt, "amount"),
          currency: Map.get(receipt, :currency) || Map.get(receipt, "currency"),
          reference: Map.get(receipt, :reference) || Map.get(receipt, "reference") || reference
        }

      {:error, :not_found} ->
        %{status: "not_found", reference: reference}

      {:error, :payment_not_configured} ->
        %{status: "not_configured", reference: reference}

      {:error, :provider_unavailable} ->
        %{status: "unavailable", reference: reference}

      {:error, {:provider, status, message}} ->
        %{status: "provider_error", httpStatus: status, reason: message}

      {:error, reason} ->
        %{status: "error", reason: inspect(reason), reference: reference}
    end
  end

  defp likely_payment_reason(nil, provider, payment_status) do
    cond do
      payment_status == "paid" -> nil
      provider.status == "not_found" -> "Paystack has no transaction for the booking reference."
      true -> "No local payment attempt has been recorded for this booking."
    end
  end

  defp likely_payment_reason(attempt, provider, payment_status) do
    failure_reason = attempt["failureReason"]
    attempt_status = attempt["status"]

    cond do
      is_binary(failure_reason) and String.trim(failure_reason) != "" ->
        failure_reason

      payment_status == "paid" ->
        nil

      attempt_status == "ready" ->
        "Checkout was created, but a successful payment has not been verified."

      attempt_status == "initializing" ->
        "Payment initialization is still in progress or awaiting stale-attempt recovery."

      attempt_status in ~w(failed expired superseded) ->
        "The latest payment attempt is #{attempt_status}."

      provider.status in ~w(abandoned failed reversed) ->
        "Paystack reports the transaction as #{provider.status}."

      provider.status == "not_found" ->
        "Paystack has no transaction for the latest reference."

      true ->
        nil
    end
  end

  defp latest_reference(nil, booking_reference), do: booking_reference

  defp latest_reference(attempt, booking_reference) do
    attempt["reference"] || booking_reference
  end

  defp eligible_policy_tier(booking, policy) do
    if booking.status in @cancellable_statuses, do: policy.refundTier, else: nil
  end

  defp eligible_refund_percent(booking, policy) do
    if booking.status in @cancellable_statuses, do: policy.refundPercent, else: nil
  end

  defp eligible_refund_amount(booking, policy) do
    if booking.status in @cancellable_statuses, do: policy.refundAmountMinor, else: nil
  end

  defp approval_error(postgres, error) do
    case postgres[:message] do
      "application_not_found" -> {:error, :application_not_found}
      "user_not_found" -> {:error, :application_user_not_found}
      _ -> database_error(error)
    end
  end

  defp require_admin(uid) do
    case Repo.query(
           "SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = $1 AND role_id = 'admin')",
           [uid]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :forbidden}
      {:error, error} -> database_error(error)
    end
  end

  defp iso_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp iso_date(_), do: :error

  defp iso_time(value) when is_binary(value) do
    value = String.trim(value)
    normalized = if Regex.match?(~r/^\d{2}:\d{2}$/, value), do: value <> ":00", else: value

    case Time.from_iso8601(normalized) do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  defp iso_time(_), do: :error

  defp format_time(time), do: time |> Time.truncate(:second) |> Time.to_iso8601()

  defp normalize_timezone(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: @default_timezone, else: String.slice(value, 0, 100)
  end

  defp normalize_timezone(_), do: @default_timezone

  defp required_text(value, min, max) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) >= min and String.length(value) <= max,
      do: {:ok, value},
      else: {:error, :invalid_request}
  end

  defp required_text(_, _, _), do: {:error, :invalid_request}

  defp optional_text(nil, _max), do: ""

  defp optional_text(value, max) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, max)

  defp optional_text(_, _max), do: ""

  defp reason_or_default("", default), do: default
  defp reason_or_default(value, _default), do: value

  defp optional_search(nil), do: {:ok, ""}

  defp optional_search(value) when is_binary(value) do
    value = String.trim(value)
    if String.length(value) <= 120, do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp optional_search(_), do: {:error, :invalid_request}

  defp optional_status(nil), do: {:ok, nil}
  defp optional_status(""), do: {:ok, nil}

  defp optional_status(value) when value in ~w(active inactive suspended pending),
    do: {:ok, value}

  defp optional_status(_), do: {:error, :invalid_request}

  defp optional_application_status(nil), do: {:ok, nil}
  defp optional_application_status(""), do: {:ok, nil}

  defp optional_application_status(value)
       when value in ~w(pending submitted under_review approved rejected),
       do: {:ok, value}

  defp optional_application_status(_), do: {:error, :invalid_request}

  defp optional_boolean(nil), do: {:ok, nil}
  defp optional_boolean(true), do: {:ok, true}
  defp optional_boolean(false), do: {:ok, false}
  defp optional_boolean("true"), do: {:ok, true}
  defp optional_boolean("false"), do: {:ok, false}
  defp optional_boolean(_), do: {:error, :invalid_request}

  defp optional_limit(nil), do: {:ok, 100}
  defp optional_limit(value) when is_integer(value) and value in 1..200, do: {:ok, value}

  defp optional_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..200 -> {:ok, limit}
      _ -> {:error, :invalid_request}
    end
  end

  defp optional_limit(_), do: {:error, :invalid_request}

  defp integer_amount(value) when is_integer(value), do: value
  defp integer_amount(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp integer_amount(value) when is_float(value), do: round(value)
  defp integer_amount(_), do: 0

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, {:database, error}}), do: database_error(error)
  defp normalize_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_transaction({:error, error}), do: database_error(error)

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(error) do
    Logger.error("Direct operations database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end