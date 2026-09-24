defmodule Mithril.MobileFunctions.DeletePropertyMedia do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.SupabaseStorage

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @bucket "property-media"

  def call(user_id, body) when is_map(body) do
    media_id = body |> Map.get("media_id", "") |> to_string() |> String.trim()

    cond do
      not Regex.match?(@uuid_regex, media_id) ->
        {:error, {:status, 400, %{error: "media_id must be a UUID"}}}

      true ->
        with {:ok, media_row} <- load_media(media_id),
             :ok <- ensure_owner(media_row, user_id),
             :ok <- remove_storage(Map.get(media_row, "storage_path")),
             :ok <- delete_metadata(media_row, user_id) do
          {:ok, %{success: true, media_id: media_id}}
        end
    end
  end

  defp load_media(media_id) do
    sql = """
    SELECT id, property_id, owner_id, storage_path
    FROM public.property_media
    WHERE id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [media_id]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, map_row(columns, row)}
      {:ok, %{rows: []}} -> {:error, {:status, 404, %{error: "Media not found"}}}
      {:error, _} -> {:error, {:status, 500, %{error: "Could not load media"}}}
    end
  end

  defp ensure_owner(media_row, user_id) do
    property_id = Map.get(media_row, "property_id")

    with {:ok, property_row} <- load_property(property_id) do
      if Map.get(property_row, "customer_id") == user_id and
           Map.get(media_row, "owner_id") == user_id do
        :ok
      else
        {:error, {:status, 403, %{error: "Forbidden"}}}
      end
    end
  end

  defp load_property(property_id) do
    sql = "SELECT id, customer_id FROM public.properties WHERE id = $1::uuid LIMIT 1"

    case Repo.query(sql, [property_id]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, map_row(columns, row)}
      _ -> {:error, {:status, 404, %{error: "Property not found"}}}
    end
  end

  defp remove_storage(storage_path) do
    path = storage_path |> to_string() |> String.trim()

    if path == "" do
      {:error, {:status, 500, %{error: "Media path missing"}}}
    else
      case SupabaseStorage.remove_object(@bucket, path) do
        :ok ->
          :ok

        {:error, :failed} ->
          {:error,
           {:status, 502, %{error: "Could not delete media file", code: "storage_delete_failed"}}}

        {:error, :not_configured} ->
          {:error, {:status, 500, %{error: "Server misconfigured"}}}
      end
    end
  end

  defp delete_metadata(media_row, user_id) do
    media_id = Map.get(media_row, "id")
    storage_path = Map.get(media_row, "storage_path")

    case Repo.query("DELETE FROM public.property_media WHERE id = $1::uuid", [media_id]) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        _ =
          Repo.query(
            """
            INSERT INTO public.property_media_cleanup_failures
              (media_id, property_id, owner_id, storage_path, error_message)
            VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5)
            """,
            [
              media_id,
              Map.get(media_row, "property_id"),
              user_id,
              storage_path,
              Exception.message(error)
            ]
          )

        {:error,
         {:status, 500,
          %{
            error: "File removed but metadata cleanup failed. Retry shortly.",
            code: "metadata_cleanup_failed"
          }}}
    end
  end

  defp map_row(columns, row), do: Map.new(Enum.zip(columns, row))
end

defmodule Mithril.MobileFunctions.UberTripEstimate do
  @moduledoc false

  alias Mithril.Posthog
  alias Mithril.Repo
  alias Mithril.Uber.TripEstimate

  @quote_ttl_ms 15 * 60 * 1000

  def call(user_id, body) when is_map(body) do
    enabled =
      Posthog.fetch_boolean_flag(
        Posthog.booking_uber_transportation_flag(),
        Posthog.uber_release_gate_distinct_id()
      )

    with {:ok, request} <- TripEstimate.parse_request(body),
         :ok <- ensure_related_cleaner(user_id, request.cleaner_id),
         true <- enabled,
         :ok <- rate_limit(user_id),
         :ok <- ensure_cleaner_active(request.cleaner_id),
         {:ok, origin} <- load_cleaner_origin(request.cleaner_id),
         estimate_input <-
           Map.merge(request, %{
             cleaner_latitude: origin.latitude,
             cleaner_longitude: origin.longitude
           }),
         {:ok, estimate} <- safe_fetch_estimate(estimate_input),
         {:ok, response} <- maybe_persist_quote(user_id, estimate_input, estimate) do
      {:ok, response}
    else
      false ->
        {:error,
         {:status, 404,
          %{error: "Cleaner transportation is currently unavailable", code: "feature_disabled"}}}

      {:error, :unrelated_cleaner} ->
        {:error, {:status, 403, %{error: "Forbidden", code: "cleaner_not_related"}}}

      {:error, message} when is_binary(message) ->
        {:error, {:status, 400, %{error: message}}}

      {:error, :rate_limited} ->
        {:error,
         {:status, 429, %{error: "Too many transportation estimate requests. Try again shortly."}}}

      {:error, :cleaner_inactive} ->
        {:error,
         {:status, 422,
          %{
            error: "Cleaner is not available for transportation estimates",
            code: "cleaner_inactive"
          }}}

      {:error, :cleaner_location_missing} ->
        {:error,
         {:status, 422,
          %{
            error: "Cleaner does not have a usable profile location",
            code: "cleaner_location_missing"
          }}}

      {:error, {:status, status, body}} ->
        {:error, {:status, status, body}}
    end
  end

  defp ensure_related_cleaner(user_id, cleaner_id) when user_id == cleaner_id, do: :ok

  defp ensure_related_cleaner(user_id, cleaner_id) do
    sql = """
    SELECT 1
    WHERE EXISTS (
      SELECT 1
      FROM public.bookings
      WHERE customer_id = $1::uuid
        AND cleaner_id = $2::uuid
        AND status IN ('pending', 'confirmed', 'scheduled', 'en_route', 'arrived', 'in_progress')
    )
    OR EXISTS (
      SELECT 1
      FROM public.preferred_cleaners
      WHERE user_id = $1::uuid AND cleaner_id = $2::uuid
    )
    OR EXISTS (
      SELECT 1
      FROM public.jobs
      WHERE customer_id = $1::uuid
        AND claimed_by = $2::uuid
        AND status NOT IN ('cancelled', 'completed', 'expired')
    )
    """

    case Repo.query(sql, [user_id, cleaner_id]) do
      {:ok, %{rows: [[_]]}} -> :ok
      _ -> {:error, :unrelated_cleaner}
    end
  end

  defp load_cleaner_origin(cleaner_id) do
    case TripEstimate.load_cleaner_origin(cleaner_id) do
      {:ok, origin} -> {:ok, origin}
      {:error, :missing} -> {:error, :cleaner_location_missing}
    end
  end

  defp rate_limit(user_id) do
    one_minute_ago = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

    case Repo.query(
           """
           SELECT count(*)::int
           FROM public.uber_transportation_quotes
           WHERE customer_id = $1::uuid AND created_at >= $2::timestamptz
           """,
           [user_id, one_minute_ago]
         ) do
      {:ok, %{rows: [[count]]}} when count >= 8 -> {:error, :rate_limited}
      _ -> :ok
    end
  end

  defp ensure_cleaner_active(cleaner_id) do
    case Repo.query("SELECT status FROM public.cleaner_data WHERE user_id = $1::uuid LIMIT 1", [
           cleaner_id
         ]) do
      {:ok, %{rows: [["active"]]}} ->
        :ok

      {:ok, %{rows: [[status]]}} when is_binary(status) ->
        if String.downcase(status) == "active", do: :ok, else: {:error, :cleaner_inactive}

      _ ->
        {:error, :cleaner_inactive}
    end
  end

  defp safe_fetch_estimate(input) do
    case TripEstimate.fetch_estimate(input) do
      {:ok, estimate} -> {:ok, estimate}
      {:error, _} -> {:error, "Could not estimate trip"}
    end
  rescue
    ArgumentError -> {:error, "Could not estimate trip"}
  end

  defp maybe_persist_quote(user_id, request, estimate) do
    base =
      estimate
      |> Map.new(fn {key, value} -> {key, value} end)

    if (estimate.currency_code == "GHS" and estimate.customer_fee_major) &&
         estimate.customer_fee_major > 0 do
      quote_expires_at = DateTime.utc_now() |> DateTime.add(@quote_ttl_ms, :millisecond)
      amount_minor = max(1, round(estimate.customer_fee_major * 100))

      case Repo.query(
             """
             INSERT INTO public.uber_transportation_quotes (
               customer_id, cleaner_id, amount_minor, currency,
               customer_latitude, customer_longitude, distance_km, duration_seconds,
               product_id, product_name, estimate_display, expires_at
             ) VALUES (
               $1::uuid, $2::uuid, $3, 'GHS', $4, $5, $6, $7, $8, $9, $10, $11::timestamptz
             )
             RETURNING id
             """,
             [
               user_id,
               request.cleaner_id,
               amount_minor,
               request.customer_latitude,
               request.customer_longitude,
               estimate.distance_km,
               estimate.duration_seconds,
               estimate.product_id,
               estimate.product_name,
               estimate.estimate_display,
               DateTime.to_iso8601(quote_expires_at)
             ]
           ) do
        {:ok, %{rows: [[quote_id]]}} ->
          {:ok,
           Map.merge(base, %{
             quote_id: quote_id,
             quote_expires_at: DateTime.to_iso8601(quote_expires_at)
           })}

        _ ->
          {:ok, base}
      end
    else
      {:ok, base}
    end
  end
end
