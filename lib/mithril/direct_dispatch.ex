defmodule Mithril.DirectDispatch do
  @moduledoc """
  Concierge and dispatch operations for Instaclean Direct.

  Urgent help is a household-services dispatch workflow, not an emergency
  medical service. Replacement dispatch preserves the original booking service
  so a worker must remain eligible for that same service.
  """

  require Logger

  alias Mithril.Auth
  alias Mithril.DirectBookings
  alias Mithril.Notifications
  alias Mithril.Repo

  @roles ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
  @priorities ~w(urgent same_day standard)
  @admin_sources ~w(admin phone whatsapp)
  # `assigned` is intentionally excluded. Only the vetted assignment endpoint
  # may move a request into the assigned state.
  @admin_statuses ~w(submitted triaging matching resolved cancelled)
  @terminal_request_statuses ~w(resolved cancelled)

  def list_service_requests(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT jsonb_build_object(
               'id', r.id,
               'kind', r.kind,
               'status', r.status,
               'priority', r.priority,
               'role', r.role,
               'requestedStartAt', r.requested_start_at,
               'durationHours', r.duration_hours,
               'householdAddress', r.household_address_snapshot,
               'relatedBookingId', r.related_booking_id,
               'requirements', r.requirements,
               'notes', r.notes,
               'assignedWorkerUserId', r.assigned_worker_user_id,
               'assignedWorkerName', CASE
                 WHEN r.assigned_worker_user_id IS NULL THEN NULL
                 ELSE COALESCE(
                   NULLIF(btrim(p.fullname), ''),
                   NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
                   'Instaclean professional'
                 )
               END,
               'createdAt', r.created_at,
               'updatedAt', r.updated_at
             )
             FROM public.direct_service_requests r
             LEFT JOIN public.profiles p ON p.id = r.assigned_worker_user_id
             WHERE r.customer_id = $1
             ORDER BY r.created_at DESC
             """,
             [uid]
           ) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, error} -> database_error(error)
    end
  end

  def create_urgent_request(user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, input} <- validate_urgent_request(params),
         {:ok, result} <-
           Repo.query(
             """
             INSERT INTO public.direct_service_requests (
               customer_id, kind, status, priority, role, requested_start_at,
               duration_hours, household_address_snapshot, requirements, notes,
               created_by_user_id
             ) VALUES (
               $1, 'urgent_help', 'submitted', $2, $3, $4, $5, $6,
               $7::text::jsonb, NULLIF($8::text, ''), $1
             )
             RETURNING id::text, status
             """,
             [
               uid,
               input.priority,
               input.role,
               input.needed_by,
               input.duration_hours,
               input.household_address,
               Jason.encode!(input.requirements),
               input.notes
             ]
           ) do
      [[id, status]] = result.rows
      {:ok, %{id: id, status: status, kind: "urgent_help"}}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  def request_replacement(user_id, booking_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, input} <- validate_replacement_request(params) do
      Repo.transaction(fn ->
        with {:ok, booking} <- fetch_replaceable_booking(uid, bid),
             {:ok, requested_start_at} <- replacement_requested_start(input, booking),
             {:ok, result} <-
               Repo.query(
                 """
                 INSERT INTO public.direct_service_requests (
                   customer_id, kind, status, priority, role, requested_start_at,
                   duration_hours, household_address_snapshot, related_booking_id,
                   related_service_id, requirements, notes, created_by_user_id
                 ) VALUES (
                   $1, 'replacement', 'submitted', $2, NULL, $3, $4, $5, $6,
                   $7, $8::text::jsonb, NULLIF($9::text, ''), $1
                 )
                 RETURNING id::text, status
                 """,
                 [
                   uid,
                   input.priority,
                   requested_start_at,
                   booking.duration_hours,
                   booking.address,
                   bid,
                   booking.service_id,
                   Jason.encode!(input.requirements),
                   input.notes
                 ]
               ) do
          [[id, status]] = result.rows
          %{id: id, status: status, kind: "replacement", relatedBookingId: booking_id}
        else
          {:error,
           %Postgrex.Error{
             postgres: %{constraint: "direct_service_requests_active_replacement_uniq"}
           }} ->
            Repo.rollback(:replacement_already_requested)

          {:error, reason} when is_atom(reason) ->
            Repo.rollback(reason)

          {:error, error} ->
            Repo.rollback({:database, error})
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :not_found}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def list_admin_customers(user_id, query) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, search} <- validate_customer_search(query),
         {:ok, result} <- search_customers(search) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  def create_admin_booking(user_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, input} <- validate_admin_booking(params),
         :ok <- require_admin(admin_uid),
         :ok <- ensure_customer_exists(input.customer_uuid),
         {:ok, dates} <- expand_booking_dates(params) do
      Repo.transaction(fn ->
        with :ok <- lock_admin_booking_series(input.customer_uuid, input.idempotency_key),
             {:ok, existing} <-
               find_admin_booking_series(input.customer_uuid, input.idempotency_key) do
          case existing do
            [_ | _] ->
              admin_booking_result(existing, input, false)

            [] ->
              created =
                dates
                |> Enum.with_index()
                |> Enum.map(fn {date, index} ->
                  booking_params =
                    params
                    |> Map.take([
                      "serviceId",
                      "cleanerId",
                      "scheduledTime",
                      "durationHours",
                      "address",
                      "specialInstructions",
                      "timezone"
                    ])
                    |> Map.put("scheduledDate", date)
                    |> maybe_put_admin_idempotency_key(input.idempotency_key, date, index)

                  case DirectBookings.create_booking(input.customer_user_id, booking_params) do
                    {:ok, booking} ->
                      case insert_booking_origin(
                             booking.id,
                             input.customer_uuid,
                             admin_uid,
                             input.source,
                             input.admin_note
                           ) do
                        {:ok, _origin_created?} ->
                          Map.merge(booking, %{
                            scheduledDate: date,
                            customerUserId: input.customer_user_id,
                            source: input.source,
                            createdByAdmin: true
                          })

                        {:error, error} ->
                          Repo.rollback({:database, error})
                      end

                    {:error, reason} ->
                      Repo.rollback(reason)
                  end
                end)

              admin_booking_result(created, input, true)
          end
        else
          {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
          {:error, error} -> Repo.rollback({:database, error})
        end
      end)
      |> normalize_transaction()
      |> case do
        {:ok, result} ->
          created_new? = result.createdNew
          public_result = Map.delete(result, :createdNew)

          notifications_sent =
            created_new? and notify_created_booking(public_result, input, params)

          {:ok, Map.put(public_result, :notificationsSent, notifications_sent)}

        error ->
          error
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp admin_booking_result(bookings, input, created_new?) do
    total_amount_minor =
      Enum.reduce(bookings, 0, fn booking, sum -> sum + booking.amountMinor end)

    first = hd(bookings)

    %{
      id: first.id,
      status: first.status,
      paymentStatus: first.paymentStatus,
      amountMinor: total_amount_minor,
      currency: first.currency,
      customerUserId: input.customer_user_id,
      source: Map.get(first, :source, input.source),
      createdByAdmin: true,
      count: length(bookings),
      bookings: bookings,
      createdNew: created_new?
    }
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
         {:ok, rid} <- dump_uuid(request_id),
         {:ok, worker_uid} <- dump_uuid(params["workerUserId"]),
         :ok <- require_admin(admin_uid) do
      Repo.transaction(fn ->
        request = fetch_request_for_update(rid)
        :ok = ensure_request_open(request.status)
        :ok = ensure_dispatch_candidate(worker_uid, request.role, request.service_id)

        case Repo.query(
               """
               UPDATE public.direct_service_requests
               SET status = 'assigned',
                   assigned_worker_user_id = $2,
                   assigned_by_user_id = $3,
                   assigned_at = now(),
                   admin_note = COALESCE(NULLIF($4::text, ''), admin_note),
                   updated_at = now()
               WHERE id = $1
               RETURNING id::text, status
               """,
               [rid, worker_uid, admin_uid, optional_text(params["adminNote"], 2_000)]
             ) do
          {:ok, %{rows: [[id, status]]}} ->
            %{id: id, status: status, assignedWorkerUserId: params["workerUserId"]}

          {:ok, %{rows: []}} ->
            Repo.rollback(:not_found)

          {:error, error} ->
            Repo.rollback({:database, error})
        end
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def update_admin_service_request(user_id, request_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, rid} <- dump_uuid(request_id),
         {:ok, status} <- admin_status(params["status"]),
         :ok <- require_admin(admin_uid),
         {:ok, result} <-
           Repo.query(
             """
             UPDATE public.direct_service_requests
             SET status = $2,
                 admin_note = COALESCE(NULLIF($3::text, ''), admin_note),
                 updated_at = now()
             WHERE id = $1
               AND status NOT IN ('resolved', 'cancelled')
             RETURNING id::text, status
             """,
             [rid, status, optional_text(params["adminNote"], 2_000)]
           ) do
      case result.rows do
        [[id, updated_status]] -> {:ok, %{id: id, status: updated_status}}
        [] -> {:error, :request_closed}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp fetch_replaceable_booking(uid, bid) do
    case Repo.query(
           """
           SELECT b.address,
                  ((b.scheduled_date + b.scheduled_time)
                    AT TIME ZONE COALESCE(
                      NULLIF(btrim(to_jsonb(b)->>'timezone_name'), ''),
                      NULLIF(btrim(to_jsonb(b)->>'timezone'), ''),
                      'Africa/Accra'
                    )),
                  b.duration_hours,
                  b.status,
                  b.payment_status,
                  b.service_id
           FROM public.bookings b
           WHERE b.id = $1 AND b.customer_id = $2
           LIMIT 1
           FOR UPDATE
           """,
           [bid, uid]
         ) do
      {:ok,
       %{
         rows: [[address, requested_start_at, duration_hours, status, payment_status, service_id]]
       }} ->
        cond do
          String.downcase(to_string(payment_status)) != "paid" ->
            {:error, :booking_unpaid}

          String.downcase(to_string(status)) not in ~w(pending confirmed scheduled) ->
            {:error, :booking_closed}

          true ->
            {:ok,
             %{
               address: address,
               requested_start_at: requested_start_at,
               duration_hours: duration_hours,
               service_id: service_id
             }}
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp search_customers(""), do: {:ok, %{rows: []}}

  defp search_customers(search) do
    like = "%#{String.downcase(search)}%"

    Repo.query(
      """
      SELECT jsonb_build_object(
        'userId', u.id,
        'name', COALESCE(
          NULLIF(btrim(p.fullname), ''),
          NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
          u.email,
          u.phone,
          'Customer'
        ),
        'email', u.email,
        'phone', u.phone
      )
      FROM public.users u
      LEFT JOIN public.profiles p ON p.id = u.id
      WHERE lower(COALESCE(u.email, '')) LIKE $1
         OR lower(COALESCE(u.phone, '')) LIKE $1
         OR lower(COALESCE(p.fullname, '')) LIKE $1
         OR lower(COALESCE(p.firstname, '') || ' ' || COALESCE(p.lastname, '')) LIKE $1
      ORDER BY COALESCE(p.fullname, u.email, u.phone, '') ASC
      LIMIT 20
      """,
      [like]
    )
  end

  defp ensure_customer_exists(customer_uuid) do
    case Repo.query("SELECT EXISTS(SELECT 1 FROM public.users WHERE id = $1)", [customer_uuid]) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :customer_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_request_for_update(rid) do
    case Repo.query(
           """
           SELECT status, role, related_service_id
           FROM public.direct_service_requests
           WHERE id = $1
           FOR UPDATE
           """,
           [rid]
         ) do
      {:ok, %{rows: [[status, role, service_id]]}} ->
        %{status: status, role: role, service_id: service_id}

      {:ok, %{rows: []}} ->
        Repo.rollback(:not_found)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp ensure_request_open(status) do
    if status in @terminal_request_statuses do
      Repo.rollback(:request_closed)
    else
      :ok
    end
  end

  defp ensure_dispatch_candidate(worker_uid, _role, service_id) when is_integer(service_id) do
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
           [worker_uid, service_id]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> Repo.rollback(:candidate_unavailable)
      {:error, error} -> Repo.rollback({:database, error})
    end
  end

  defp ensure_dispatch_candidate(worker_uid, role, nil) do
    case Repo.query(
           """
           SELECT cd.verified,
                  cd.status,
                  COALESCE(pcp.placement_opt_in, false),
                  COALESCE(pcp.placement_status, 'inactive'),
                  COALESCE(pcp.desired_roles, ARRAY[]::text[])
           FROM public.cleaner_data cd
           LEFT JOIN public.placement_candidate_profiles pcp ON pcp.user_id = cd.user_id
           WHERE cd.user_id = $1
           LIMIT 1
           """,
           [worker_uid]
         ) do
      {:ok, %{rows: [[true, "active", opt_in, placement_status, desired_roles]]}} ->
        role_ok =
          role == "cleaner" or
            (opt_in == true and placement_status == "available" and role in (desired_roles || []))

        if role_ok, do: :ok, else: Repo.rollback(:candidate_unavailable)

      {:ok, _} ->
        Repo.rollback(:candidate_unavailable)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp validate_urgent_request(params) do
    with {:ok, role} <- role(params["role"]),
         {:ok, priority} <- priority(params["priority"] || "urgent"),
         {:ok, needed_by} <- iso_datetime(params["neededBy"]),
         {:ok, duration_hours} <- duration_hours(params["durationHours"]),
         {:ok, household_address} <- required_text(params["householdAddress"], 3, 500),
         {:ok, request_requirements} <- requirements(params["requirements"]) do
      {:ok,
       %{
         role: role,
         priority: priority,
         needed_by: needed_by,
         duration_hours: duration_hours,
         household_address: household_address,
         requirements: request_requirements,
         notes: optional_text(params["notes"], 4_000)
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_replacement_request(params) do
    with {:ok, priority} <- priority(params["priority"] || "same_day"),
         {:ok, needed_by} <- optional_iso_datetime(params["neededBy"]),
         {:ok, request_requirements} <- requirements(params["requirements"]) do
      {:ok,
       %{
         priority: priority,
         needed_by: needed_by,
         requirements: request_requirements,
         notes: optional_text(params["notes"], 4_000)
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp replacement_requested_start(%{needed_by: %DateTime{} = needed_by}, _booking) do
    minimum = DateTime.add(DateTime.utc_now(), 60, :second)

    if DateTime.compare(needed_by, minimum) == :gt,
      do: {:ok, needed_by},
      else: {:error, :needed_by_past}
  end

  defp replacement_requested_start(%{needed_by: nil}, %{requested_start_at: requested_start_at}) do
    minimum = DateTime.add(DateTime.utc_now(), 60, :second)

    if DateTime.compare(requested_start_at, minimum) == :gt,
      do: {:ok, requested_start_at},
      else: {:error, :replacement_time_required}
  end

  defp notify_created_booking(result, input, params) do
    if Notifications.enabled?(params) do
      Notifications.notify(%{
        send_notifications: true,
        kind: :assisted_booking,
        customer: Notifications.load_party(input.customer_user_id),
        worker: Notifications.load_party(params["cleanerId"]),
        booking_id: result.id,
        count: result.count,
        dates: Enum.map(result.bookings, &booking_notify_date/1),
        scheduled_time: params["scheduledTime"],
        address: params["address"]
      })
    else
      false
    end
  end

  defp booking_notify_date(%{scheduledDate: date}) when is_binary(date), do: date
  defp booking_notify_date(%{"scheduledDate" => date}) when is_binary(date), do: date
  defp booking_notify_date(_), do: nil

  defp insert_booking_origin(booking_id, customer_uuid, admin_uid, source, admin_note) do
    case Repo.query(
           """
           INSERT INTO public.direct_booking_origins (
             booking_id, customer_id, created_by_user_id, source,
             consent_confirmed, admin_note
           ) VALUES ($1::uuid, $2, $3, $4, true, NULLIF($5::text, ''))
           ON CONFLICT (booking_id) DO NOTHING
           RETURNING booking_id
           """,
           [booking_id, customer_uuid, admin_uid, source, admin_note]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, true}
      {:ok, %{num_rows: 0}} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_put_admin_idempotency_key(params, nil, _date, _index), do: params

  defp maybe_put_admin_idempotency_key(params, key, date, index) do
    Map.put(params, "idempotencyKey", admin_booking_idempotency_key(key, date, index))
  end

  defp lock_admin_booking_series(_customer_uuid, nil), do: :ok

  defp lock_admin_booking_series(customer_uuid, key) do
    customer_key = Base.encode16(customer_uuid, case: :lower)
    lock_key = "direct-admin-booking:#{customer_key}:#{admin_booking_series_prefix(key)}"

    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [lock_key]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp find_admin_booking_series(_customer_uuid, nil), do: {:ok, []}

  defp find_admin_booking_series(customer_uuid, key) do
    prefix = admin_booking_series_prefix(key)

    case Repo.query(
           """
           SELECT b.id::text,
                  b.status::text,
                  b.payment_status::text,
                  COALESCE(b.final_amount_minor, b.total_price)::bigint,
                  COALESCE(b.currency, 'GHS'),
                  b.scheduled_date::text,
                  o.source
           FROM public.bookings b
           JOIN public.direct_booking_origins o ON o.booking_id = b.id
           WHERE b.customer_id = $1
             AND left(b.idempotency_key, length($2)) = $2
           ORDER BY b.idempotency_key ASC
           """,
           [customer_uuid, prefix]
         ) do
      {:ok, result} ->
        {:ok, Enum.map(result.rows, &admin_booking_series_row/1)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp admin_booking_series_row([
         id,
         status,
         payment_status,
         amount_minor,
         currency,
         date,
         source
       ]) do
    %{
      id: id,
      status: status,
      paymentStatus: payment_status,
      amountMinor: amount_minor,
      currency: currency,
      scheduledDate: date,
      source: source
    }
  end

  defp admin_booking_series_prefix(key) do
    digest =
      :crypto.hash(:sha256, String.trim(key))
      |> Base.url_encode64(padding: false)

    "admin:#{digest}:"
  end

  @doc false
  def admin_booking_idempotency_key(key, _date, index)
      when is_binary(key) and is_integer(index) and index >= 0 do
    suffix = index |> Integer.to_string() |> String.pad_leading(2, "0")
    admin_booking_series_prefix(key) <> suffix
  end

  def expand_booking_dates(params) do
    case params["scheduleKind"] || "once" do
      "once" ->
        case iso_date(params["scheduledDate"]) do
          {:ok, date} -> {:ok, [Date.to_iso8601(date)]}
          _ -> {:error, :invalid_request}
        end

      "custom_days" ->
        parse_custom_dates(params["customDates"])

      "recurring" ->
        expand_recurring_dates(params)

      _ ->
        {:error, :invalid_request}
    end
  end

  defp parse_custom_dates(dates) when is_list(dates) do
    parsed =
      dates
      |> Enum.map(&iso_date/1)
      |> Enum.reduce_while([], fn
        {:ok, date}, acc -> {:cont, [date | acc]}
        _, _ -> {:halt, :error}
      end)

    cond do
      parsed == :error -> {:error, :invalid_request}
      parsed == [] -> {:error, :invalid_request}
      length(parsed) > 14 -> {:error, :invalid_request}
      true -> {:ok, parsed |> Enum.uniq() |> Enum.sort() |> Enum.map(&Date.to_iso8601/1)}
    end
  end

  defp parse_custom_dates(_), do: {:error, :invalid_request}

  defp expand_recurring_dates(params) do
    with {:ok, start_date} <- iso_date(params["scheduledDate"]),
         {:ok, interval} <- recurrence_interval(params["recurrenceInterval"]),
         {:ok, count} <- occurrence_count(params["occurrenceCount"]) do
      dates =
        0..(count - 1)
        |> Enum.map(&shift_recurrence(start_date, interval, &1))
        |> Enum.map(&Date.to_iso8601/1)

      {:ok, dates}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp recurrence_interval(value) when value in ~w(weekly bi_weekly monthly), do: {:ok, value}
  defp recurrence_interval(_), do: :error

  defp occurrence_count(value) when is_integer(value) and value >= 2 and value <= 12,
    do: {:ok, value}

  defp occurrence_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} -> occurrence_count(count)
      _ -> :error
    end
  end

  defp occurrence_count(_), do: :error

  defp shift_recurrence(date, "weekly", index), do: Date.add(date, 7 * index)
  defp shift_recurrence(date, "bi_weekly", index), do: Date.add(date, 14 * index)
  defp shift_recurrence(date, "monthly", index), do: Date.shift(date, month: index)

  defp iso_date(value) when is_binary(value), do: Date.from_iso8601(String.trim(value))
  defp iso_date(%Date{} = date), do: {:ok, date}
  defp iso_date(_), do: :error

  defp validate_admin_booking(params) do
    with true <- params["consentConfirmed"] == true,
         {:ok, customer_uuid} <- dump_uuid(params["customerUserId"]),
         {:ok, source} <- admin_source(params["source"] || "admin"),
         {:ok, idempotency_key} <- optional_idempotency_key(params["idempotencyKey"]) do
      {:ok,
       %{
         customer_uuid: customer_uuid,
         customer_user_id: params["customerUserId"],
         source: source,
         admin_note: optional_text(params["adminNote"], 2_000),
         idempotency_key: idempotency_key
       }}
    else
      false -> {:error, :consent_required}
      _ -> {:error, :invalid_request}
    end
  end

  defp optional_idempotency_key(nil), do: {:ok, nil}

  defp optional_idempotency_key(value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) >= 8 and String.length(value) <= 128,
      do: {:ok, value},
      else: :error
  end

  defp optional_idempotency_key(_), do: :error

  defp validate_customer_search(value) when is_binary(value) do
    value = String.trim(value)
    if String.length(value) <= 120, do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp validate_customer_search(nil), do: {:ok, ""}
  defp validate_customer_search(_), do: {:error, :invalid_request}

  defp role(value) when value in @roles, do: {:ok, value}
  defp role(_), do: :error

  defp priority(value) when value in @priorities, do: {:ok, value}
  defp priority(_), do: :error

  defp admin_source(value) when value in @admin_sources, do: {:ok, value}
  defp admin_source(_), do: :error

  defp admin_status(value) when value in @admin_statuses, do: {:ok, value}
  defp admin_status(_), do: :error

  defp iso_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp iso_datetime(_), do: :error

  defp optional_iso_datetime(nil), do: {:ok, nil}
  defp optional_iso_datetime(""), do: {:ok, nil}
  defp optional_iso_datetime(value), do: iso_datetime(value)

  defp duration_hours(value) when is_integer(value) and value >= 1 and value <= 24,
    do: {:ok, Decimal.new(value)}

  defp duration_hours(value) when is_float(value) and value >= 0.5 and value <= 24,
    do: {:ok, Decimal.from_float(value)}

  defp duration_hours(_), do: :error

  defp requirements(nil), do: {:ok, %{}}
  defp requirements(value) when is_map(value), do: {:ok, value}
  defp requirements(_), do: :error

  defp required_text(value, min, max) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) >= min and String.length(value) <= max,
      do: {:ok, value},
      else: :error
  end

  defp required_text(_, _, _), do: :error

  defp optional_text(nil, _max), do: ""

  defp optional_text(value, max) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, max)

  defp optional_text(_, _max), do: ""

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, {:database, error}}), do: database_error(error)
  defp normalize_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_transaction({:error, error}), do: database_error(error)

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(error) do
    Logger.error("Direct dispatch database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
