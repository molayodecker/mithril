defmodule Mithril.DirectAdminLiveJobs do
  @moduledoc """
  Staff live board: assigned jobs that are on the way, on site, in progress,
  or scheduled for today in Ghana.
  """

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  @on_job ~w(en_route arrived in_progress)
  @assigned_today ~w(confirmed scheduled)

  def list(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid) do
      extras = progress_tables()

      case load_jobs(extras) do
        {:ok, jobs} ->
          {:ok,
           %{
             "generatedAt" =>
               DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
             "jobs" => jobs
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_jobs(extras) do
    case Repo.query(jobs_sql(extras)) do
      {:ok, result} ->
        {:ok, Enum.map(result.rows, &hd/1)}

      {:error, error} ->
        database_error(error)
    end
  end

  defp jobs_sql(extras) do
    """
    SELECT jsonb_build_object(
      'bookingId', b.id,
      'status', b.status::text,
      'serviceName', st.name,
      'scheduledDate', b.scheduled_date,
      'scheduledTime', b.scheduled_time,
      'durationHours', b.duration_hours::float,
      'timezone', COALESCE(NULLIF(btrim(b.timezone), ''), 'Africa/Accra'),
      'address', b.address,
      'latitude', #{lat_expr(extras.coordinates)},
      'longitude', #{lng_expr(extras.coordinates)},
      'customerName', COALESCE(
        NULLIF(btrim(cp.fullname), ''),
        NULLIF(btrim(concat_ws(' ', cp.firstname, cp.lastname)), ''),
        NULLIF(btrim(cu.email), ''),
        NULLIF(btrim(cu.phone), ''),
        'Customer'
      ),
      'customerPhone', cu.phone,
      'cleanerId', b.cleaner_id,
      'cleanerName', COALESCE(
        NULLIF(btrim(wp.fullname), ''),
        NULLIF(btrim(concat_ws(' ', wp.firstname, wp.lastname)), ''),
        'Instaclean professional'
      ),
      'cleanerPhone', wu.phone,
      'updatedAt', b.updated_at,
      'milestones', #{milestones_expr(extras.timeline)},
      'tracking', #{tracking_expr(extras.tracking)},
      'photos', #{photos_expr(extras.photos)}
    )
    FROM public.bookings b
    JOIN public.service_types st ON st.id = b.service_id
    JOIN public.users cu ON cu.id = b.customer_id
    LEFT JOIN public.profiles cp ON cp.id = b.customer_id
    LEFT JOIN public.users wu ON wu.id = b.cleaner_id
    LEFT JOIN public.profiles wp ON wp.id = b.cleaner_id
    WHERE b.cleaner_id IS NOT NULL
      AND (
        b.status::text = ANY(ARRAY[#{sql_list(@on_job)}])
        OR (
          b.status::text = ANY(ARRAY[#{sql_list(@assigned_today)}])
          AND b.scheduled_date = (timezone('Africa/Accra', now()))::date
        )
      )
    ORDER BY
      CASE b.status::text
        WHEN 'in_progress' THEN 0
        WHEN 'arrived' THEN 1
        WHEN 'en_route' THEN 2
        ELSE 3
      END,
      b.scheduled_time ASC NULLS LAST,
      b.updated_at DESC
    LIMIT 200
    """
  end

  defp lat_expr(:json), do: safe_json_coordinate_expr(["latitude", "lat"], -90, 90)
  defp lat_expr(:spatial), do: "ST_Y(b.location_coordinates::geometry)"
  defp lat_expr(:point), do: "(b.location_coordinates)[1]::double precision"
  defp lat_expr(_), do: "NULL::double precision"

  defp lng_expr(:json), do: safe_json_coordinate_expr(["longitude", "lng"], -180, 180)
  defp lng_expr(:spatial), do: "ST_X(b.location_coordinates::geometry)"
  defp lng_expr(:point), do: "(b.location_coordinates)[0]::double precision"
  defp lng_expr(_), do: "NULL::double precision"

  defp safe_json_coordinate_expr(keys, min, max) do
    value =
      keys
      |> Enum.map_join(", ", &"NULLIF(b.location_coordinates->>'#{&1}', '')")
      |> then(&"COALESCE(#{&1})")

    """
    CASE
      WHEN #{value} ~ '^[+-]?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$' THEN
        CASE
          WHEN (#{value})::double precision BETWEEN #{min} AND #{max}
          THEN (#{value})::double precision
          ELSE NULL::double precision
        END
      ELSE NULL::double precision
    END
    """
  end

  defp milestones_expr(true) do
    """
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('stage', tl.stage::text, 'changedAt', tl.changed_at)
        ORDER BY tl.changed_at ASC NULLS LAST
      )
      FROM public.booking_timeline tl
      WHERE tl.booking_id = b.id
    ), '[]'::jsonb)
    """
  end

  defp milestones_expr(false), do: "'[]'::jsonb"

  defp tracking_expr(true) do
    """
    (
      SELECT jsonb_build_object(
        'latitude', ct.latitude,
        'longitude', ct.longitude,
        'heading', ct.heading,
        'accuracy', ct.accuracy,
        'updatedAt', ct.created_at
      )
      FROM public.cleaner_tracking ct
      WHERE ct.booking_id = b.id
      ORDER BY ct.created_at DESC
      LIMIT 1
    )
    """
  end

  defp tracking_expr(false), do: "NULL::jsonb"

  defp photos_expr(true) do
    """
    COALESCE((
      SELECT jsonb_build_object(
        'before', COUNT(*) FILTER (WHERE p.photo_type = 'before'),
        'during', COUNT(*) FILTER (WHERE p.photo_type = 'during'),
        'after', COUNT(*) FILTER (WHERE p.photo_type = 'after'),
        'issue', COUNT(*) FILTER (WHERE p.photo_type = 'issue'),
        'total', COUNT(*)
      )
      FROM public.booking_job_photos p
      WHERE p.booking_id = b.id
    ), jsonb_build_object('before', 0, 'during', 0, 'after', 0, 'issue', 0, 'total', 0))
    """
  end

  defp photos_expr(false) do
    "jsonb_build_object('before', 0, 'during', 0, 'after', 0, 'issue', 0, 'total', 0)"
  end

  defp progress_tables do
    case Repo.query("""
         SELECT
           to_regclass('public.booking_timeline') IS NOT NULL,
           to_regclass('public.cleaner_tracking') IS NOT NULL,
           to_regclass('public.booking_job_photos') IS NOT NULL,
           (
             SELECT c.udt_name
             FROM information_schema.columns c
             WHERE c.table_schema = 'public'
               AND c.table_name = 'bookings'
               AND c.column_name = 'location_coordinates'
             LIMIT 1
           )
         """) do
      {:ok, %{rows: [[timeline, tracking, photos, coordinate_type]]}} ->
        %{
          timeline: truthy?(timeline),
          tracking: truthy?(tracking),
          photos: truthy?(photos),
          coordinates: coordinate_kind(coordinate_type)
        }

      _ ->
        %{timeline: false, tracking: false, photos: false, coordinates: :none}
    end
  end

  defp coordinate_kind(type) when type in ["json", "jsonb"], do: :json
  defp coordinate_kind(type) when type in ["geometry", "geography"], do: :spatial
  defp coordinate_kind("point"), do: :point
  defp coordinate_kind(_), do: :none

  defp truthy?(value) when value in [true, 1, "t", "true"], do: true
  defp truthy?(_), do: false

  defp sql_list(values) do
    Enum.map_join(values, ", ", &"'#{&1}'")
  end

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin live jobs database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
