defmodule Mithril.DirectDispatchSafety do
  @moduledoc """
  Server-side safety checks for Direct concierge dispatch.

  These checks sit in front of the existing dispatch mutations so customer UI
  rules are never the only protection for paid replacements, worker schedule
  availability, replacement handoff, or request-state transitions.
  """

  require Logger

  alias Mithril.DirectDispatch
  alias Mithril.Repo

  @default_timezone "Africa/Accra"
  @assignable_statuses ~w(submitted triaging matching)
  @mutable_statuses ~w(triaging matching resolved cancelled)

  def request_replacement(user_id, booking_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- ensure_paid_owned_booking(uid, bid) do
      DirectDispatch.request_replacement(user_id, booking_id, params)
    else
      :error -> {:error, :not_found}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  def list_admin_service_requests(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, result} <-
           Repo.query("""
           SELECT jsonb_build_object(
             'id', r.id,
             'customerUserId', r.customer_id,
             'customerName', COALESCE(
               NULLIF(btrim(cp.fullname), ''),
               NULLIF(btrim(concat_ws(' ', cp.firstname, cp.lastname)), ''),
               cu.email,
               cu.phone,
               'Customer'
             ),
             'customerPhone', cu.phone,
             'kind', r.kind,
             'status', r.status,
             'priority', r.priority,
             'role', r.role,
             'requestedStartAt', r.requested_start_at,
             'durationHours', r.duration_hours,
             'householdAddress', r.household_address_snapshot,
             'relatedBookingId', r.related_booking_id,
             'relatedServiceId', r.related_service_id,
             'requirements', r.requirements,
             'notes', r.notes,
             'adminNote', r.admin_note,
             'assignedWorkerUserId', r.assigned_worker_user_id,
             'assignedWorkerName', CASE
               WHEN r.assigned_worker_user_id IS NULL THEN NULL
               ELSE COALESCE(
                 NULLIF(btrim(wp.fullname), ''),
                 NULLIF(btrim(concat_ws(' ', wp.firstname, wp.lastname)), ''),
                 'Instaclean professional'
               )
             END,
             'createdAt', r.created_at,
             'updatedAt', r.updated_at
           )
           FROM public.direct_service_requests r
           JOIN public.users cu ON cu.id = r.customer_id
           LEFT JOIN public.profiles cp ON cp.id = r.customer_id
           LEFT JOIN public.profiles wp ON wp.id = r.assigned_worker_user_id
           ORDER BY
             CASE r.status
               WHEN 'submitted' THEN 0
               WHEN 'triaging' THEN 1
               WHEN 'matching' THEN 2
               WHEN 'assigned' THEN 3
               ELSE 4
             END,
             CASE r.priority
               WHEN 'urgent' THEN 0
               WHEN 'same_day' THEN 1
               ELSE 2
             END,
             r.created_at ASC
           LIMIT 200
           """) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  def assign_admin_service_request(user_id, request_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, rid} <- dump_uuid(request_id),
         {:ok, worker_uid} <- dump_uuid(params["workerUserId"]) do
      Repo.transaction(fn ->
        with :ok <- lock_worker_schedule(worker_uid),
             {:ok, request} <- fetch_request_window_for_update(rid),
             :ok <- ensure_assignable_request(request.status),
             {:ok, request} <- resolve_assignment_window(request, params, rid),
             :ok <- ensure_worker_available(worker_uid, request),
             :ok <- reassign_related_booking(request, worker_uid),
             {:ok, assigned} <-
               DirectDispatch.assign_admin_service_request(user_id, request_id, params) do
          assigned
        else
          {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
          {:error, error} -> Repo.rollback({:database, error})
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  def update_admin_service_request(user_id, request_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, rid} <- dump_uuid(request_id),
         {:ok, target_status} <- mutable_status(params["status"]) do
      Repo.transaction(fn ->
        with {:ok, request} <- fetch_request_state_for_update(rid),
             :ok <- ensure_status_transition(request, target_status),
             {:ok, updated} <-
               DirectDispatch.update_admin_service_request(user_id, request_id, params) do
          updated
        else
          {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
          {:error, error} -> Repo.rollback({:database, error})
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp ensure_paid_owned_booking(uid, bid) do
    case Repo.query(
           """
           SELECT payment_status
           FROM public.bookings
           WHERE id = $1 AND customer_id = $2
           LIMIT 1
           """,
           [bid, uid]
         ) do
      {:ok, %{rows: [[status]]}} ->
        if String.downcase(to_string(status)) == "paid",
          do: :ok,
          else: {:error, :booking_unpaid}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp lock_worker_schedule(worker_uid) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1::uuid::text, 0))",
           [worker_uid]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_request_window_for_update(rid) do
    case Repo.query(
           """
           SELECT r.status,
                  r.kind,
                  r.related_booking_id,
                  r.related_service_id,
                  r.requested_start_at,
                  r.duration_hours,
                  COALESCE(NULLIF(b.timezone, ''), $2::text) AS request_timezone
           FROM public.direct_service_requests r
           LEFT JOIN public.bookings b ON b.id = r.related_booking_id
           WHERE r.id = $1
           LIMIT 1
           FOR UPDATE OF r
           """,
           [rid, @default_timezone]
         ) do
      {:ok,
       %{
         rows: [
           [
             status,
             kind,
             related_booking_id,
             related_service_id,
             %DateTime{} = requested_start_at,
             duration_hours,
             request_timezone
           ]
         ]
       }}
      when not is_nil(duration_hours) ->
        {:ok,
         %{
           status: status,
           kind: kind,
           related_booking_id: related_booking_id,
           related_service_id: related_service_id,
           requested_start_at: requested_start_at,
           duration_hours: duration_hours,
           request_timezone: request_timezone
         }}

      {:ok, %{rows: [_]}} ->
        {:error, :invalid_request}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_request_state_for_update(rid) do
    case Repo.query(
           """
           SELECT status, kind
           FROM public.direct_service_requests
           WHERE id = $1
           LIMIT 1
           FOR UPDATE
           """,
           [rid]
         ) do
      {:ok, %{rows: [[status, kind]]}} -> {:ok, %{status: status, kind: kind}}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_assignable_request(status) when status in @assignable_statuses, do: :ok
  defp ensure_assignable_request(_), do: {:error, :request_closed}

  defp resolve_assignment_window(request, params, rid) do
    with {:ok, override} <- optional_assignment_datetime(params["neededBy"]),
         requested_start_at <- override || request.requested_start_at,
         :ok <- ensure_future_assignment(requested_start_at),
         {:ok, exception_date} <- exception_date(requested_start_at, request.request_timezone),
         :ok <- persist_assignment_override(rid, override) do
      {:ok,
       request
       |> Map.put(:requested_start_at, requested_start_at)
       |> Map.put(:exception_date, exception_date)}
    end
  end

  defp optional_assignment_datetime(nil), do: {:ok, nil}
  defp optional_assignment_datetime(""), do: {:ok, nil}

  defp optional_assignment_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_request}
    end
  end

  defp optional_assignment_datetime(_), do: {:error, :invalid_request}

  defp ensure_future_assignment(%DateTime{} = requested_start_at) do
    minimum = DateTime.add(DateTime.utc_now(), 60, :second)

    if DateTime.compare(requested_start_at, minimum) == :gt,
      do: :ok,
      else: {:error, :needed_by_past}
  end

  defp exception_date(requested_start_at, timezone) do
    case Repo.query(
           "SELECT ($1::timestamptz AT TIME ZONE COALESCE(NULLIF($2::text, ''), $3::text))::date",
           [requested_start_at, timezone, @default_timezone]
         ) do
      {:ok, %{rows: [[%Date{} = date]]}} -> {:ok, date}
      {:error, error} -> {:error, error}
    end
  end

  defp persist_assignment_override(_rid, nil), do: :ok

  defp persist_assignment_override(rid, %DateTime{} = requested_start_at) do
    case Repo.query(
           "UPDATE public.direct_service_requests SET requested_start_at = $2, updated_at = now() WHERE id = $1",
           [rid, requested_start_at]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_worker_available(worker_uid, request) do
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
               $2::timestamptz
                 + make_interval(secs => ($3::numeric * 3600)::double precision),
               NULL
             )
           """,
           [
             worker_uid,
             request.requested_start_at,
             request.duration_hours,
             request.exception_date
           ]
         ) do
      {:ok, %{rows: [[false, false]]}} -> :ok
      {:ok, %{rows: [[true, _]]}} -> {:error, :candidate_unavailable}
      {:ok, %{rows: [[_, true]]}} -> {:error, :candidate_unavailable}
      {:error, error} -> {:error, error}
    end
  end

  defp reassign_related_booking(%{kind: "urgent_help"}, _worker_uid), do: :ok

  defp reassign_related_booking(
         request = %{
           kind: "replacement",
           related_booking_id: booking_id,
           related_service_id: service_id
         },
         worker_uid
       )
       when not is_nil(booking_id) and not is_nil(service_id) do
    case Repo.query(
           """
           SELECT cleaner_id, status, payment_status, service_id, timezone
           FROM public.bookings
           WHERE id = $1
           LIMIT 1
           FOR UPDATE
           """,
           [booking_id]
         ) do
      {:ok, %{rows: [[current_worker, status, payment_status, ^service_id, timezone]]}} ->
        cond do
          String.downcase(to_string(payment_status)) != "paid" ->
            {:error, :booking_unpaid}

          String.downcase(to_string(status)) not in ~w(pending confirmed scheduled) ->
            {:error, :booking_closed}

          current_worker == worker_uid ->
            {:error, :candidate_unavailable}

          true ->
            persist_replacement_handoff(
              booking_id,
              current_worker,
              worker_uid,
              request.requested_start_at,
              request.duration_hours,
              timezone
            )
        end

      {:ok, %{rows: [[_, _, _, _, _]]}} ->
        {:error, :invalid_request}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp reassign_related_booking(_request, _worker_uid), do: {:error, :invalid_request}

  defp persist_replacement_handoff(
         booking_id,
         previous_worker,
         worker_uid,
         requested_start_at,
         duration_hours,
         timezone
       ) do
    with {:ok, _} <-
           Repo.query("SELECT set_config('app.booking_assignment_write', '1', true)"),
         {:ok, _} <-
           Repo.query(
             """
             UPDATE public.direct_service_requests
             SET previous_worker_user_id = COALESCE(previous_worker_user_id, $2),
                 updated_at = now()
             WHERE related_booking_id = $1
               AND kind = 'replacement'
               AND status IN ('submitted', 'triaging', 'matching')
             """,
             [booking_id, previous_worker]
           ),
         {:ok, %{rows: [[_]]}} <-
           Repo.query(
             """
             UPDATE public.bookings
             SET cleaner_id = $2,
                 direct_assigned_cleaner_id = $2,
                 scheduled_date = (($3::timestamptz AT TIME ZONE COALESCE(NULLIF($5::text, ''), 'Africa/Accra'))::date),
                 scheduled_time = (($3::timestamptz AT TIME ZONE COALESCE(NULLIF($5::text, ''), 'Africa/Accra'))::time),
                 booking_period = tstzrange(
                   $3::timestamptz,
                   $3::timestamptz + make_interval(secs => ($4::numeric * 3600)::double precision),
                   '[)'
                 ),
                 cleaner_accepted_at = now(),
                 assignment_phase = 'accepted',
                 assignment_hold_until = NULL,
                 assignment_reminder_sent_at = NULL,
                 updated_at = now(),
                 last_updated = now()
             WHERE id = $1
             RETURNING id
             """,
             [booking_id, worker_uid, requested_start_at, duration_hours, timezone]
           ) do
      :ok
    else
      {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} ->
        {:error, :candidate_unavailable}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_status_transition(%{status: "submitted"}, target)
       when target in ~w(triaging matching cancelled),
       do: :ok

  defp ensure_status_transition(%{status: "triaging"}, target)
       when target in ~w(matching cancelled),
       do: :ok

  defp ensure_status_transition(%{status: "matching"}, "cancelled"), do: :ok
  defp ensure_status_transition(%{status: "assigned"}, "resolved"), do: :ok

  defp ensure_status_transition(%{status: "assigned", kind: "urgent_help"}, "cancelled"),
    do: :ok

  defp ensure_status_transition(_request, _target), do: {:error, :invalid_status_transition}

  defp mutable_status(status) when status in @mutable_statuses, do: {:ok, status}
  defp mutable_status(_), do: :error

  defp require_admin(uid) do
    case Repo.query(
           "SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = $1 AND role_id = 'admin')",
           [uid]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, {:database, error}}), do: database_error(error)
  defp normalize_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_transaction({:error, error}), do: database_error(error)

  defp database_error(error) do
    Logger.error("Direct dispatch safety database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
