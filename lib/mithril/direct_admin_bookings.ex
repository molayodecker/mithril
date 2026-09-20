defmodule Mithril.DirectAdminBookings do
  @moduledoc """
  Staff booking desk: list, inspect, assign, status, cancel, reschedule,
  exclusive-hold reset, cash payout, and outreach nudges.
  """

  require Logger

  alias Mithril.Auth
  alias Mithril.DirectBookingCancels
  alias Mithril.DirectBookings
  alias Mithril.Notifications
  alias Mithril.Repo

  @reassignable ~w(pending confirmed scheduled)
  @assignable_statuses ~w(pending confirmed scheduled en_route arrived in_progress completed)
  @assignable_hold_statuses ~w(pending confirmed scheduled)
  @default_timezone "Africa/Accra"

  def list_bookings(user_id, params \\ %{}) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, filters} <- validate_list_filters(params),
         {:ok, result} <-
           Repo.query(
             """
             SELECT #{booking_json_select()}
             FROM public.bookings b
             JOIN public.service_types st ON st.id = b.service_id
             JOIN public.users cu ON cu.id = b.customer_id
             LEFT JOIN public.profiles cp ON cp.id = b.customer_id
             LEFT JOIN public.users wu ON wu.id = b.cleaner_id
             LEFT JOIN public.profiles wp ON wp.id = b.cleaner_id
             LEFT JOIN public.wallets w ON w.user_id = b.cleaner_id
             LEFT JOIN LATERAL (
               SELECT pm.bank_name, pm.masked_account, pm.account_name, pm.account_number
               FROM public.payout_methods pm
               WHERE pm.user_id = b.cleaner_id
               ORDER BY COALESCE(pm.is_primary, false) DESC,
                        COALESCE(pm.is_default, false) DESC,
                        pm.updated_at DESC NULLS LAST
               LIMIT 1
             ) pay ON true
             WHERE ($1::text = '' OR (
               b.address ILIKE '%' || $1 || '%'
               OR COALESCE(cu.email, '') ILIKE '%' || $1 || '%'
               OR COALESCE(cu.phone, '') ILIKE '%' || $1 || '%'
               OR COALESCE(cp.fullname, '') ILIKE '%' || $1 || '%'
               OR COALESCE(wp.fullname, '') ILIKE '%' || $1 || '%'
               OR b.id::text ILIKE '%' || $1 || '%'
             ))
               AND ($2::text = '' OR b.status::text = $2)
               AND ($3::text = '' OR COALESCE(b.payment_status::text, '') = $3)
             ORDER BY b.scheduled_date DESC NULLS LAST,
                      b.scheduled_time DESC NULLS LAST,
                      b.created_at DESC
             LIMIT 150
             """,
             [filters.search, filters.status, filters.payment_status]
           ) do
      {:ok, Enum.map(result.rows, fn [booking] -> with_flags(booking) end)}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  def get_booking(user_id, booking_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(uid) do
      fetch_booking(bid)
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def assign_cleaner(user_id, booking_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, cleaner_uid} <- dump_uuid(params["cleanerId"] || params[:cleanerId]),
         :ok <- require_admin(admin_uid) do
      Repo.transaction(fn ->
        with {:ok, booking} <- lock_booking_for_assignment(bid) do
          if booking.current_cleaner_id == cleaner_uid do
            repair_same_cleaner_reservation(cleaner_uid, booking)
          else
            with :ok <- ensure_reassignable(booking),
                 :ok <- lock_cleaner_schedule(cleaner_uid),
                 :ok <- ensure_cleaner_role(cleaner_uid),
                 :ok <- ensure_dispatch_cleaner(cleaner_uid, booking.service_id),
                 :ok <- ensure_assignment_window(booking),
                 :ok <- ensure_cleaner_available(cleaner_uid, booking),
                 :ok <- persist_cleaner_assignment(bid, cleaner_uid, booking) do
              :ok
            else
              {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
              {:error, error} -> Repo.rollback({:database, error})
            end
          end
        else
          {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
          {:error, error} -> Repo.rollback({:database, error})
        end
      end)
      |> normalize_transaction()
      |> case do
        {:ok, :ok} -> fetch_booking(bid)
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_status(user_id, booking_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, status} <- validate_status(params["status"] || params[:status]),
         :ok <- require_admin(admin_uid) do
      case Repo.query(
             """
             UPDATE public.bookings
             SET status = $2, updated_at = now()
             WHERE id = $1 AND status::text <> 'cancelled'
             RETURNING id
             """,
             [bid, status]
           ) do
        {:ok, %{num_rows: 1}} -> fetch_booking(bid)
        {:ok, %{num_rows: 0}} -> {:error, :not_found}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel(user_id, booking_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(admin_uid),
         {:ok, customer_id} <- booking_customer_id(bid) do
      DirectBookingCancels.cancel(customer_id, booking_id, params, {:admin, user_id})
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def reschedule(user_id, booking_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(admin_uid),
         {:ok, customer_id} <- booking_customer_id(bid) do
      case DirectBookings.reschedule(customer_id, booking_id, params) do
        {:ok, _} -> fetch_booking(bid)
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def reset_exclusive_hold(user_id, booking_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(admin_uid),
         {:ok, cleaner_uid} <- optional_uuid(params["cleanerId"] || params[:cleanerId]) do
      case Repo.query(
             """
             SELECT public.admin_reset_exclusive_accept_hold(
               p_booking_id := $1::uuid,
               p_cleaner_id := $2::uuid,
               p_admin_user_id := $3::uuid
             )
             """,
             [bid, cleaner_uid, admin_uid]
           ) do
        {:ok, %{rows: [[payload]]}} ->
          if rpc_ok?(payload) do
            {:ok, %{"ok" => true}}
          else
            {:error, rpc_atom(payload)}
          end

        {:error, error} ->
          map_rpc_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_cash_payout(user_id, booking_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, amount} <- positive_int(params["amountMinor"] || params[:amountMinor]),
         :ok <- require_admin(admin_uid),
         {:ok, booking} <- fetch_booking(bid),
         {:ok, cleaner_uid} <- dump_uuid(booking["cleanerId"]),
         notes <- optional_notes(params["notes"] || params[:notes]) do
      case Repo.query(
             """
             SELECT public.record_admin_cash_payout(
               p_cleaner_id := $1::uuid,
               p_amount_subunit := $2::bigint,
               p_recorded_by := $3::uuid,
               p_booking_id := $4::uuid,
               p_notes := $5::text
             )
             """,
             [cleaner_uid, amount, admin_uid, bid, notes]
           ) do
        {:ok, %{rows: [[payload]]}} ->
          {:ok,
           %{
             "amountMinor" => amount,
             "newBalanceMinor" => rpc_int(payload, "new_balance_subunit")
           }}

        {:error, error} ->
          map_rpc_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def notify_cleaner(user_id, booking_id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(admin_uid),
         {:ok, booking} <- fetch_booking(bid),
         cleaner_id when is_binary(cleaner_id) <- booking["cleanerId"] do
      sent =
        Notifications.notify(%{
          kind: :admin_notify_cleaner,
          recipient: :worker,
          worker: Notifications.load_party(cleaner_id),
          customer: Notifications.load_party(booking["customerId"]),
          dates: List.wrap(booking["scheduledDate"]),
          scheduled_time: booking["scheduledTime"],
          address: booking["address"] || "",
          booking_id: booking["id"]
        })

      {:ok, %{"ok" => true, "sent" => sent == true}}
    else
      nil -> {:error, :cleaner_missing}
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_receipt(user_id, booking_id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(admin_uid),
         {:ok, booking} <- fetch_booking(bid),
         customer when is_map(customer) <- Notifications.load_party(booking["customerId"]) do
      if is_nil(customer[:phone]) and is_nil(customer[:email]) do
        {:error, :missing_contact}
      else
        sent =
          Notifications.notify(%{
            kind: :admin_receipt,
            recipient: :customer,
            customer: customer,
            worker: Notifications.load_party(booking["cleanerId"]),
            dates: List.wrap(booking["scheduledDate"]),
            scheduled_time: booking["scheduledTime"],
            address: booking["address"] || "",
            booking_id: booking["id"],
            amount_minor: booking["amountMinor"],
            currency: booking["currency"] || "GHS"
          })

        {:ok, %{"ok" => true, "sent" => sent == true}}
      end
    else
      nil -> {:error, :missing_contact}
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_booking(bid) do
    case Repo.query(
           """
           SELECT #{booking_json_select()}
           FROM public.bookings b
           JOIN public.service_types st ON st.id = b.service_id
           JOIN public.users cu ON cu.id = b.customer_id
           LEFT JOIN public.profiles cp ON cp.id = b.customer_id
           LEFT JOIN public.users wu ON wu.id = b.cleaner_id
           LEFT JOIN public.profiles wp ON wp.id = b.cleaner_id
           LEFT JOIN public.wallets w ON w.user_id = b.cleaner_id
           LEFT JOIN LATERAL (
             SELECT pm.bank_name, pm.masked_account, pm.account_name, pm.account_number
             FROM public.payout_methods pm
             WHERE pm.user_id = b.cleaner_id
             ORDER BY COALESCE(pm.is_primary, false) DESC,
                      COALESCE(pm.is_default, false) DESC,
                      pm.updated_at DESC NULLS LAST
             LIMIT 1
           ) pay ON true
           WHERE b.id = $1
           LIMIT 1
           """,
           [bid]
         ) do
      {:ok, %{rows: [[booking]]}} -> {:ok, with_flags(booking)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp booking_json_select do
    """
    jsonb_build_object(
      'id', b.id,
      'status', b.status::text,
      'paymentStatus', b.payment_status::text,
      'serviceId', b.service_id,
      'serviceName', st.name,
      'scheduledDate', b.scheduled_date,
      'scheduledTime', b.scheduled_time,
      'durationHours', b.duration_hours::float,
      'timezone', b.timezone,
      'address', b.address,
      'specialInstructions', b.special_instructions,
      'amountMinor', ROUND(COALESCE(b.final_amount_minor::numeric, b.total_price::numeric, 0))::bigint,
      'cleanerEarningsMinor', ROUND(COALESCE(b.cleaner_earnings_minor::numeric, 0))::bigint,
      'currency', COALESCE(b.currency, 'GHS'),
      'customerId', b.customer_id,
      'customerName', COALESCE(
        NULLIF(btrim(cp.fullname), ''),
        NULLIF(btrim(concat_ws(' ', cp.firstname, cp.lastname)), ''),
        NULLIF(btrim(cu.email), ''),
        NULLIF(btrim(cu.phone), ''),
        'Customer'
      ),
      'customerEmail', cu.email,
      'customerPhone', cu.phone,
      'cleanerId', b.cleaner_id,
      'cleanerName', CASE
        WHEN b.cleaner_id IS NULL THEN NULL
        ELSE COALESCE(
          NULLIF(btrim(wp.fullname), ''),
          NULLIF(btrim(concat_ws(' ', wp.firstname, wp.lastname)), ''),
          'Instaclean professional'
        )
      END,
      'cleanerPhone', wu.phone,
      'cleanerEmail', wu.email,
      'walletBalanceMinor', w.balance_subunit::bigint,
      'walletCurrency', w.currency,
      'payoutMethod', CASE
        WHEN pay.account_number IS NULL THEN NULL
        ELSE jsonb_build_object(
          'bankName', pay.bank_name,
          'maskedAccount', pay.masked_account,
          'accountName', pay.account_name,
          'accountNumber', pay.account_number
        )
      END,
      'assignmentPhase', b.assignment_phase,
      'assignmentHoldUntil', b.assignment_hold_until,
      'cleanerAcceptedAt', b.cleaner_accepted_at,
      'directAssignedCleanerId', b.direct_assigned_cleaner_id,
      'createdAt', b.created_at,
      'updatedAt', b.updated_at
    )
    """
  end

  defp with_flags(booking) when is_map(booking) do
    status = to_string(booking["status"] || "")
    payment = to_string(booking["paymentStatus"] || "")
    earnings = booking["cleanerEarningsMinor"] || 0

    Map.merge(booking, %{
      "canReassignCleaner" => status in @reassignable,
      "canCancel" => status not in ~w(cancelled completed),
      "canChangeStatus" => status != "cancelled",
      "canResetHold" => can_reset_hold?(booking),
      "canRecordCashPayout" =>
        status == "completed" and payment == "paid" and is_binary(booking["cleanerId"]) and
          earnings > 0
    })
  end

  defp can_reset_hold?(booking) do
    status = to_string(booking["status"] || "")
    payment = to_string(booking["paymentStatus"] || "")
    phase = booking["assignmentPhase"]
    accepted = booking["cleanerAcceptedAt"]
    target = booking["directAssignedCleanerId"] || booking["cleanerId"]

    payment == "paid" and is_nil(accepted) and status in @assignable_hold_statuses and
      is_binary(target) and
      (phase in [nil, "broadcast", "exclusive"] or phase == "")
  end

  defp booking_customer_id(bid) do
    case Repo.query("SELECT customer_id::text FROM public.bookings WHERE id = $1 LIMIT 1", [bid]) do
      {:ok, %{rows: [[customer_id]]}} when is_binary(customer_id) -> {:ok, customer_id}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  # Assignment mutations use one global lock order: booking row first,
  # then the target cleaner schedule advisory lock. Same-cleaner retries skip
  # mutable worker validation, but may still repair a missing legacy period.
  defp lock_cleaner_schedule(cleaner_uid) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1::uuid::text, 0))",
           [cleaner_uid]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp lock_booking_for_assignment(bid) do
    case Repo.query(
           """
           SELECT
             status::text,
             service_id,
             cleaner_id,
             booking_period IS NULL AS missing_booking_period,
             COALESCE(
               lower(booking_period),
               (scheduled_date + scheduled_time)
                 AT TIME ZONE COALESCE(
                   NULLIF(btrim(to_jsonb(b)->>'timezone_name'), ''),
                   NULLIF(btrim(to_jsonb(b)->>'timezone'), ''),
                   $2::text
                 )
             ) AS starts_at,
             COALESCE(
               upper(booking_period),
               ((scheduled_date + scheduled_time)
                 AT TIME ZONE COALESCE(
                   NULLIF(btrim(to_jsonb(b)->>'timezone_name'), ''),
                   NULLIF(btrim(to_jsonb(b)->>'timezone'), ''),
                   $2::text
                 ))
                 + make_interval(secs => (duration_hours * 3600)::double precision)
             ) AS ends_at,
             scheduled_date
           FROM public.bookings b
           WHERE b.id = $1
           FOR UPDATE
           """,
           [bid, @default_timezone]
         ) do
      {:ok,
       %{
         rows: [
           [
             status,
             service_id,
             current_cleaner_id,
             missing_booking_period,
             starts_at,
             ends_at,
             scheduled_date
           ]
         ]
       }} ->
        {:ok,
         %{
           status: status,
           service_id: service_id,
           current_cleaner_id: current_cleaner_id,
           missing_booking_period: missing_booking_period,
           starts_at: starts_at,
           ends_at: ends_at,
           scheduled_date: scheduled_date,
           booking_id: bid
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp repair_same_cleaner_reservation(_cleaner_uid, %{missing_booking_period: false}), do: :ok

  defp repair_same_cleaner_reservation(cleaner_uid, booking) do
    with :ok <- ensure_reservation_window(booking),
         :ok <- lock_cleaner_schedule(cleaner_uid) do
      persist_legacy_booking_period(booking)
    end
  end

  defp ensure_reservation_window(%{starts_at: %DateTime{} = starts_at, ends_at: %DateTime{} = ends_at}) do
    if DateTime.compare(ends_at, starts_at) == :gt, do: :ok, else: {:error, :invalid_timeslot}
  end

  defp ensure_reservation_window(_booking), do: {:error, :invalid_timeslot}

  defp persist_legacy_booking_period(booking) do
    case Repo.query(
           """
           UPDATE public.bookings
           SET booking_period = tstzrange($2::timestamptz, $3::timestamptz, '[)'),
               updated_at = now()
           WHERE id = $1
             AND booking_period IS NULL
           RETURNING id
           """,
           [booking.booking_id, booking.starts_at, booking.ends_at]
         ) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} ->
        {:error, :cleaner_unavailable}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_reassignable(%{status: status}) when status in @reassignable, do: :ok
  defp ensure_reassignable(_booking), do: {:error, :not_reassignable}

  defp ensure_dispatch_cleaner(cleaner_uid, service_id) do
    case Repo.query(
           """
           SELECT EXISTS(
             SELECT 1
             FROM public.cleaner_data cd
             JOIN public.service_types st ON st.id = $2
             WHERE cd.user_id = $1
               AND cd.verified = true
               AND cd.status = 'active'
               AND cd.hourly_rate IS NOT NULL
               AND cd.hourly_rate > 0
               AND st.specialty_slug = ANY(COALESCE(cd.specialties, ARRAY[]::text[]))
           )
           """,
           [cleaner_uid, service_id]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :cleaner_unavailable}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_assignment_window(%{
         starts_at: %DateTime{} = starts_at,
         ends_at: %DateTime{} = ends_at
       }) do
    cond do
      DateTime.compare(ends_at, starts_at) != :gt -> {:error, :invalid_timeslot}
      DateTime.compare(starts_at, DateTime.utc_now()) != :gt -> {:error, :past_schedule}
      true -> :ok
    end
  end

  defp ensure_assignment_window(_), do: {:error, :invalid_timeslot}

  defp ensure_cleaner_available(cleaner_uid, booking) do
    case Repo.query(
           """
           SELECT
             EXISTS(
               SELECT 1
               FROM public.cleaner_availability_exceptions cae
               WHERE cae.cleaner_id = $1
                 AND cae.exception_date = $4::date
             ),
             public.cleaner_has_booking_conflict(
               $1,
               $2::timestamptz,
               $3::timestamptz,
               $5::uuid
             )
           """,
           [
             cleaner_uid,
             booking.starts_at,
             booking.ends_at,
             booking.scheduled_date,
             booking.booking_id
           ]
         ) do
      {:ok, %{rows: [[false, false]]}} -> :ok
      {:ok, %{rows: [[true, _]]}} -> {:error, :cleaner_unavailable}
      {:ok, %{rows: [[_, true]]}} -> {:error, :cleaner_unavailable}
      {:error, error} -> {:error, error}
    end
  end

  defp persist_cleaner_assignment(bid, cleaner_uid, booking) do
    same_cleaner? = booking.current_cleaner_id == cleaner_uid

    case Repo.query(
           """
           UPDATE public.bookings
           SET cleaner_id = $2,
               direct_assigned_cleaner_id = $2,
               booking_period = COALESCE(
                 booking_period,
                 tstzrange($5::timestamptz, $6::timestamptz, '[)')
               ),
               status = CASE
                 WHEN status::text = 'pending' THEN 'confirmed'
                 ELSE status::text
               END,
               cleaner_assigned_at = CASE
                 WHEN $4::boolean THEN COALESCE(cleaner_assigned_at, now())
                 ELSE now()
               END,
               cleaner_accepted_at = CASE
                 WHEN $4::boolean THEN cleaner_accepted_at
                 ELSE NULL
               END,
               assignment_phase = CASE
                 WHEN $4::boolean THEN assignment_phase
                 ELSE NULL
               END,
               assignment_hold_until = CASE
                 WHEN $4::boolean THEN assignment_hold_until
                 ELSE NULL
               END,
               updated_at = now()
           WHERE id = $1
             AND status::text = ANY($3::text[])
           RETURNING id
           """,
           [
             bid,
             cleaner_uid,
             @reassignable,
             same_cleaner?,
             booking.starts_at,
             booking.ends_at
           ]
         ) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, :not_reassignable}

      {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} ->
        {:error, :cleaner_unavailable}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_cleaner_role(cleaner_uid) do
    case Repo.query(
           """
           SELECT EXISTS(
             SELECT 1 FROM public.user_roles
             WHERE user_id = $1 AND role_id = 'cleaner'
           )
           """,
           [cleaner_uid]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :cleaner_unavailable}
      {:error, error} -> database_error(error)
    end
  end

  defp validate_list_filters(params) do
    search =
      (params["q"] || params[:q] || "")
      |> to_string()
      |> String.trim()
      |> String.slice(0, 120)
      |> String.replace(~r/[%_]/, "")

    status = optional_slug(params["status"] || params[:status])
    payment = optional_slug(params["paymentStatus"] || params[:paymentStatus])

    cond do
      status != "" and status not in @assignable_statuses and status != "cancelled" ->
        {:error, :invalid_request}

      true ->
        {:ok, %{search: search, status: status, payment_status: payment}}
    end
  end

  defp optional_slug(nil), do: ""

  defp optional_slug(value) when is_binary(value) do
    value = String.trim(value) |> String.downcase()
    if value =~ ~r/^[a-z_]+$/, do: value, else: ""
  end

  defp optional_slug(_), do: ""

  defp validate_status(status) when is_binary(status) do
    status = String.trim(status)

    if status in @assignable_statuses do
      {:ok, status}
    else
      {:error, :invalid_status}
    end
  end

  defp validate_status(_), do: {:error, :invalid_status}

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}

  defp optional_uuid(value) when is_binary(value) do
    case dump_uuid(value) do
      {:ok, uid} -> {:ok, uid}
      :error -> {:error, :invalid_request}
    end
  end

  defp optional_uuid(_), do: {:error, :invalid_request}

  defp positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_request}
    end
  end

  defp positive_int(_), do: {:error, :invalid_request}

  defp optional_notes(nil), do: nil

  defp optional_notes(value) when is_binary(value) do
    value = String.trim(value) |> String.slice(0, 500)
    if value == "", do: nil, else: value
  end

  defp optional_notes(_), do: nil

  defp rpc_ok?(payload) when is_map(payload) do
    payload["success"] == true or payload[:success] == true
  end

  defp rpc_ok?(_), do: false

  @rpc_errors %{
    "unpaid" => :booking_not_paid,
    "already_accepted" => :already_accepted,
    "non_assignable_status" => :not_reassignable,
    "terminal_status" => :not_reassignable,
    "invalid_phase" => :invalid_request,
    "hold_still_active" => :hold_still_active,
    "booking_in_past" => :past_schedule,
    "missing_cleaner" => :cleaner_missing,
    "invalid_cleaner" => :cleaner_unavailable,
    "booking_not_found" => :not_found
  }

  defp rpc_atom(payload) when is_map(payload) do
    code = payload["error"] || payload[:error]
    Map.get(@rpc_errors, code, :unknown)
  end

  defp rpc_atom(_), do: :unknown

  defp rpc_int(payload, key) when is_map(payload) do
    value = payload[key] || payload[String.to_atom(key)]
    if is_integer(value), do: value, else: nil
  end

  defp rpc_int(_, _), do: nil

  defp map_rpc_error(%Postgrex.Error{postgres: %{message: message}}) when is_binary(message) do
    cond do
      String.contains?(message, "insufficient_balance") ->
        {:error, :insufficient_balance}

      String.contains?(message, "wallet_not_found") ->
        {:error, :wallet_not_found}

      String.contains?(message, "invalid_amount") ->
        {:error, :invalid_amount}

      String.contains?(message, "cash_payout_already_recorded") ->
        {:error, :cash_payout_already_recorded}

      String.contains?(message, "booking_has_no_cleaner_earnings") ->
        {:error, :booking_has_no_cleaner_earnings}

      String.contains?(message, "amount_exceeds_booking_earnings") ->
        {:error, :amount_exceeds_booking_earnings}

      String.contains?(message, "booking_not_completed") ->
        {:error, :booking_not_completed}

      String.contains?(message, "booking_not_paid") ->
        {:error, :booking_not_paid}

      String.contains?(message, "booking_cleaner_mismatch") ->
        {:error, :booking_cleaner_mismatch}

      String.contains?(message, "undefined_function") ->
        {:error, :database_unavailable}

      true ->
        {:error, :database_unavailable}
    end
  end

  defp map_rpc_error(error), do: database_error(error)

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, {:database, error}}), do: database_error(error)
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(error) do
    Logger.error("Direct admin bookings database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
