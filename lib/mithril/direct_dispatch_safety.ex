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

  def assign_admin_service_request(user_id, request_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, rid} <- dump_uuid(request_id),
         {:ok, worker_uid} <- dump_uuid(params["workerUserId"]),
         {:ok, request} <- fetch_request_window(rid),
         :ok <- ensure_worker_available(worker_uid, request) do
      DirectDispatch.assign_admin_service_request(user_id, request_id, params)
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

  defp fetch_request_window(rid) do
    case Repo.query(
           """
           SELECT requested_start_at, duration_hours
           FROM public.direct_service_requests
           WHERE id = $1
           LIMIT 1
           """,
           [rid]
         ) do
      {:ok, %{rows: [[%DateTime{} = requested_start_at, duration_hours]]}}
      when not is_nil(duration_hours) ->
        {:ok, %{requested_start_at: requested_start_at, duration_hours: duration_hours}}

      {:ok, %{rows: [[_, _]]}} ->
        {:error, :invalid_request}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
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
                 AND cae.exception_date = (($2::timestamptz AT TIME ZONE $4::text)::date)
             ),
             public.cleaner_has_booking_conflict(
               $1,
               $2::timestamptz,
               $2::timestamptz
                 + make_interval(secs => ($3::numeric * 3600)::double precision),
               NULL
             )
           """,
           [worker_uid, request.requested_start_at, request.duration_hours, @default_timezone]
         ) do
      {:ok, %{rows: [[false, false]]}} -> :ok
      {:ok, %{rows: [[true, _]]}} -> {:error, :candidate_unavailable}
      {:ok, %{rows: [[_, true]]}} -> {:error, :candidate_unavailable}
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

  defp database_error(error) do
    Logger.error("Direct dispatch safety database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
