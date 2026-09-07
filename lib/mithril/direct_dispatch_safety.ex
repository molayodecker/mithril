defmodule Mithril.DirectDispatchSafety do
  @moduledoc """
  Server-side safety checks for Direct concierge dispatch.

  These checks sit in front of the existing dispatch mutations so customer UI
  rules are never the only protection for paid replacements or worker schedule
  availability.
  """

  require Logger

  alias Mithril.DirectDispatch
  alias Mithril.Repo

  @default_timezone "Africa/Accra"
  @dispatch_buffer_minutes 45

  def request_replacement(user_id, booking_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         {:ok, booking} <- fetch_paid_owned_booking(uid, bid) do
      DirectDispatch.request_replacement(
        user_id,
        booking_id,
        put_related_service_requirement(params, booking.service_id)
      )
    else
      :error -> {:error, :not_found}
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
             :ok <- ensure_worker_available(worker_uid, rid, request),
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

  defp fetch_paid_owned_booking(uid, bid) do
    case Repo.query(
           """
           SELECT payment_status, service_id
           FROM public.bookings
           WHERE id = $1 AND customer_id = $2
           LIMIT 1
           """,
           [bid, uid]
         ) do
      {:ok, %{rows: [[status, service_id]]}} ->
        if String.downcase(to_string(status)) == "paid",
          do: {:ok, %{service_id: service_id}},
          else: {:error, :booking_unpaid}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp put_related_service_requirement(params, service_id) do
    case params["requirements"] do
      nil ->
        Map.put(params, "requirements", %{"relatedServiceId" => service_id})

      requirements when is_map(requirements) ->
        Map.put(params, "requirements", Map.put(requirements, "relatedServiceId", service_id))

      _ ->
        params
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
           SELECT r.requested_start_at,
                  r.duration_hours,
                  COALESCE(
                    b.scheduled_date,
                    (r.requested_start_at AT TIME ZONE $2::text)::date
                  ) AS exception_date
           FROM public.direct_service_requests r
           LEFT JOIN public.bookings b ON b.id = r.related_booking_id
           WHERE r.id = $1
           LIMIT 1
           FOR UPDATE OF r
           """,
           [rid, @default_timezone]
         ) do
      {:ok,
       %{rows: [[%DateTime{} = requested_start_at, duration_hours, %Date{} = exception_date]]}}
      when not is_nil(duration_hours) ->
        {:ok,
         %{
           requested_start_at: requested_start_at,
           duration_hours: duration_hours,
           exception_date: exception_date
         }}

      {:ok, %{rows: [[_, _, _]]}} ->
        {:error, :invalid_request}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_worker_available(worker_uid, rid, request) do
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
             ),
             EXISTS(
               SELECT 1
               FROM public.direct_service_requests other
               WHERE other.id <> $5
                 AND other.assigned_worker_user_id = $1
                 AND other.status = 'assigned'
                 AND other.requested_start_at IS NOT NULL
                 AND other.duration_hours IS NOT NULL
                 AND tstzrange(
                       other.requested_start_at
                         - make_interval(mins => $6::integer),
                       other.requested_start_at
                         + make_interval(secs => (other.duration_hours * 3600)::double precision)
                         + make_interval(mins => $6::integer),
                       '[)'
                     ) &&
                     tstzrange(
                       $2::timestamptz,
                       $2::timestamptz
                         + make_interval(secs => ($3::numeric * 3600)::double precision),
                       '[)'
                     )
             )
           """,
           [
             worker_uid,
             request.requested_start_at,
             request.duration_hours,
             request.exception_date,
             rid,
             @dispatch_buffer_minutes
           ]
         ) do
      {:ok, %{rows: [[false, false, false]]}} -> :ok
      {:ok, %{rows: [[true, _, _]]}} -> {:error, :candidate_unavailable}
      {:ok, %{rows: [[_, true, _]]}} -> {:error, :candidate_unavailable}
      {:ok, %{rows: [[_, _, true]]}} -> {:error, :candidate_unavailable}
      {:error, error} -> {:error, error}
    end
  end

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
