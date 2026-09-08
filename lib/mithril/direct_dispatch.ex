defmodule Mithril.DirectDispatch do
  @moduledoc """
  Concierge and dispatch operations for Instaclean Direct.

  Urgent help is a household-services dispatch workflow, not an emergency
  medical service. Replacement dispatch preserves the original booking service
  so a worker must remain eligible for that same service.
  """

  require Logger

  alias Mithril.DirectBookings
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
         {:ok, input} <- validate_replacement_request(params),
         {:ok, booking} <- fetch_replaceable_booking(uid, bid),
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
      {:ok, %{id: id, status: status, kind: "replacement", relatedBookingId: booking_id}}
    else
      :error ->
        {:error, :not_found}

      {:error,
       %Postgrex.Error{
         postgres: %{constraint: "direct_service_requests_active_replacement_uniq"}
       }} ->
        {:error, :replacement_already_requested}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, error} ->
        database_error(error)
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
         :ok <- ensure_customer_exists(input.customer_uuid) do
      Repo.transaction(fn ->
        booking_params =
          Map.take(params, [
            "serviceId",
            "cleanerId",
            "scheduledDate",
            "scheduledTime",
            "durationHours",
            "address",
            "specialInstructions",
            "timezone"
          ])

        case DirectBookings.create_booking(input.customer_user_id, booking_params) do
          {:ok, booking} ->
            case Repo.query(
                   """
                   INSERT INTO public.direct_booking_origins (
                     booking_id, customer_id, created_by_user_id, source,
                     consent_confirmed, admin_note
                   ) VALUES ($1::uuid, $2, $3, $4, true, NULLIF($5::text, ''))
                   """,
                   [
                     booking.id,
                     input.customer_uuid,
                     admin_uid,
                     input.source,
                     input.admin_note
                   ]
                 ) do
              {:ok, _} ->
                Map.merge(booking, %{
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
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_user}
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
      {:error, error} -> database_error(error)
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
                    AT TIME ZONE COALESCE(NULLIF(b.timezone, ''), 'Africa/Accra')),
                  b.duration_hours,
                  b.status,
                  b.service_id
           FROM public.bookings b
           WHERE b.id = $1 AND b.customer_id = $2
           LIMIT 1
           """,
           [bid, uid]
         ) do
      {:ok, %{rows: [[address, requested_start_at, duration_hours, status, service_id]]}} ->
        if String.downcase(to_string(status)) not in ~w(pending confirmed scheduled) do
          {:error, :booking_closed}
        else
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

  defp validate_admin_booking(params) do
    with true <- params["consentConfirmed"] == true,
         {:ok, customer_uuid} <- dump_uuid(params["customerUserId"]),
         {:ok, source} <- admin_source(params["source"] || "admin") do
      {:ok,
       %{
         customer_uuid: customer_uuid,
         customer_user_id: params["customerUserId"],
         source: source,
         admin_note: optional_text(params["adminNote"], 2_000)
       }}
    else
      false -> {:error, :consent_required}
      _ -> {:error, :invalid_request}
    end
  end

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
    case Repo.query(
           "SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = $1 AND role_id = 'admin')",
           [uid]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
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
