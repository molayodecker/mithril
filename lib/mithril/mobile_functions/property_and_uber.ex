defmodule Mithril.MobileFunctions.DeletePropertyMedia do
  @moduledoc false

  alias Mithril.DbUuid
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

    case Repo.query(sql, [DbUuid.dump!(media_id)]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, map_row(columns, row)}
      {:ok, %{rows: []}} -> {:error, {:status, 404, %{error: "Media not found"}}}
      {:error, _} -> {:error, {:status, 500, %{error: "Could not load media"}}}
    end
  end

  defp ensure_owner(media_row, user_id) do
    property_id = Map.get(media_row, "property_id")

    with {:ok, property_row} <- load_property(property_id) do
      if DbUuid.equal?(Map.get(property_row, "customer_id"), user_id) and
           DbUuid.equal?(Map.get(media_row, "owner_id"), user_id) do
        :ok
      else
        {:error, {:status, 403, %{error: "Forbidden"}}}
      end
    end
  end

  defp load_property(property_id) do
    sql = "SELECT id, customer_id FROM public.properties WHERE id = $1::uuid LIMIT 1"

    case Repo.query(sql, [DbUuid.dump!(property_id)]) do
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

    case Repo.query("DELETE FROM public.property_media WHERE id = $1::uuid", [
           DbUuid.dump!(media_id)
         ]) do
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
              DbUuid.dump!(media_id),
              DbUuid.dump!(Map.get(media_row, "property_id")),
              DbUuid.dump!(user_id),
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

  alias Mithril.DbUuid
  alias Mithril.Repo
  alias Mithril.Transport.Estimate
  alias Mithril.Transport.Origins
  alias Mithril.Transport.Pricing
  alias Mithril.Transport.Router

  @quote_ttl_seconds 15 * 60
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    with :ok <- ensure_uuid(user_id, "customer"),
         {:ok, cleaner_id} <- required_uuid(body, "cleaner_id"),
         {:ok, latitude} <- required_coord(body, "customer_latitude", -90, 90),
         {:ok, longitude} <- required_coord(body, "customer_longitude", -180, 180) do
      case optional_uuid(body, "booking_id") do
        :absent ->
          quote_for_review(user_id, cleaner_id, latitude, longitude)

        {:ok, booking_id} ->
          quote_serialized(user_id, cleaner_id, booking_id)

        {:error, _} = error ->
          error
      end
    end
  end

  def call(_user_id, _body) do
    {:error, {:status, 400, %{error: "Cleaner and customer coordinates are required"}}}
  end

  # Review runs before a booking exists. The customer pin is the destination.
  # The worker must already be an active verified cleaner, and the response
  # never includes the worker's home coordinates.
  defp quote_for_review(user_id, cleaner_id, latitude, longitude) do
    destination = %{latitude: latitude, longitude: longitude}

    with :ok <- authorize_cleaner(cleaner_id),
         :ok <- ensure_gate(),
         {:ok, token} <- reserve_quote_slot(user_id),
         {:ok, origin} <- load_origin(cleaner_id),
         {:ok, route} <- route(origin, destination),
         {:ok, priced} <- strict_price(route.distance_km),
         :ok <- ensure_priced(priced),
         {:ok, quote} <-
           insert_quote(
             user_id,
             cleaner_id,
             nil,
             token,
             latitude,
             longitude,
             route,
             priced
           ) do
      {:ok, present(route, priced, quote)}
    end
  end

  # Reserve a per-customer slot in a short transaction before paid provider calls.
  # Every attempt counts for 15 minutes, including failed provider calls.
  defp quote_serialized(user_id, cleaner_id, booking_id) do
    with {:ok, booking} <- authorize_booking(user_id, cleaner_id, booking_id),
         :ok <- ensure_gate(),
         {:ok, token} <- reserve_quote_slot(user_id) do
      with {:ok, destination} <- booking_destination(booking),
           {:ok, origin} <- load_origin(cleaner_id),
           {:ok, route} <- route(origin, destination),
           {:ok, priced} <- strict_price(route.distance_km),
           :ok <- ensure_priced(priced),
           {:ok, quote} <-
             insert_quote(
               user_id,
               cleaner_id,
               booking_id,
               token,
               destination.latitude,
               destination.longitude,
               route,
               priced
             ) do
        {:ok, present(route, priced, quote)}
      end
    end
  end

  defp reserve_quote_slot(user_id) do
    case Repo.transaction(fn ->
           with {:ok, _} <-
                  Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
                    "transport-quote:" <> user_id
                  ]),
                {:ok, _} <-
                  Repo.query(
                    "DELETE FROM public.transport_quote_reservations WHERE customer_id = $1::uuid AND expires_at <= now()",
                    [DbUuid.dump!(user_id)]
                  ),
                :ok <- enforce_limit(user_id),
                {:ok, %{rows: [[pending]]}} <-
                  Repo.query(
                    """
                    SELECT count(*) FROM public.transport_quote_reservations
                    WHERE customer_id = $1::uuid AND expires_at > now()
                    """,
                    [DbUuid.dump!(user_id)]
                  ),
                :ok <- ensure_pending_capacity(user_id, pending),
                {:ok, %{rows: [[token]]}} <-
                  Repo.query(
                    """
                    INSERT INTO public.transport_quote_reservations (customer_id, expires_at)
                    VALUES ($1::uuid, now() + interval '15 minutes')
                    RETURNING id::text
                    """,
                    [DbUuid.dump!(user_id)]
                  ) do
             token
           else
             {:error, reason} -> Repo.rollback(reason)
             _ -> Repo.rollback({:status, 503, %{error: "Quote reservation unavailable"}})
           end
         end) do
      {:ok, token} -> {:ok, token}
      {:error, {:status, _, _} = reason} -> {:error, reason}
      {:error, _} -> {:error, {:status, 503, %{error: "Quote reservation unavailable"}}}
    end
  end

  defp ensure_pending_capacity(user_id, pending) do
    case Repo.query(
           """
           SELECT count(*) FROM public.uber_transportation_quotes
           WHERE customer_id = $1::uuid AND revoked_at IS NULL AND expires_at > now()
           """,
           [DbUuid.dump!(user_id)]
         ) do
      {:ok, %{rows: [[count]]}} when count + pending < 5 -> :ok
      {:ok, _} -> {:error, {:status, 429, %{error: "Too many active transport quotes"}}}
      {:error, _} -> {:error, {:status, 503, %{error: "Quote limit unavailable"}}}
    end
  end

  defp ensure_uuid(value, label) do
    if is_binary(value) and Regex.match?(@uuid_regex, value) do
      :ok
    else
      {:error, {:status, 400, %{error: "Invalid #{label} id"}}}
    end
  end

  defp required_uuid(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if Regex.match?(@uuid_regex, value) do
          {:ok, value}
        else
          {:error, {:status, 400, %{error: "Invalid #{key}"}}}
        end

      _ ->
        {:error, {:status, 400, %{error: "Invalid #{key}"}}}
    end
  end

  defp optional_uuid(body, key) do
    case Map.get(body, key) do
      nil ->
        :absent

      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" -> :absent
          Regex.match?(@uuid_regex, trimmed) -> {:ok, trimmed}
          true -> {:error, {:status, 400, %{error: "Invalid #{key}"}}}
        end

      _ ->
        {:error, {:status, 400, %{error: "Invalid #{key}"}}}
    end
  end

  defp required_coord(body, key, min, max) do
    case Map.get(body, key) do
      value when is_number(value) and value >= min and value <= max ->
        {:ok, value * 1.0}

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
          _ -> {:error, {:status, 400, %{error: "Invalid #{key}"}}}
        end

      _ ->
        {:error, {:status, 400, %{error: "Invalid #{key}"}}}
    end
  end

  # A review quote has no booking yet. Confirm the selected user is an active
  # verified cleaner before reading the private trip origin.
  defp authorize_cleaner(cleaner_id) do
    case Repo.query(
           """
           SELECT 1
           FROM public.user_roles ur
           INNER JOIN public.cleaner_data cd ON cd.user_id = ur.user_id
           WHERE ur.user_id = $1::uuid
             AND ur.role_id = 'cleaner'
             AND cd.status = 'active'
             AND cd.verified IS TRUE
           LIMIT 1
           """,
           [DbUuid.dump!(cleaner_id)]
         ) do
      {:ok, %{rows: [[1]]}} ->
        :ok

      {:ok, _} ->
        {:error, {:status, 404, %{error: "Cleaner not found"}}}

      {:error, _} ->
        {:error, {:status, 503, %{error: "Cleaner authorization unavailable"}}}
    end
  end

  # Only the customer of an existing booking can request a route from its
  # assigned cleaner. Never allow arbitrary cleaner UUIDs to reveal home locations.
  defp authorize_booking(user_id, cleaner_id, booking_id) do
    case Repo.query(
           """
           SELECT id, customer_id, address FROM public.bookings
           WHERE id = $1::uuid AND customer_id = $2::uuid AND cleaner_id = $3::uuid
             AND status IN ('pending', 'confirmed', 'scheduled', 'en_route', 'arrived', 'in_progress')
           LIMIT 1
           """,
           [DbUuid.dump!(booking_id), DbUuid.dump!(user_id), DbUuid.dump!(cleaner_id)]
         ) do
      {:ok, %{rows: [[_id, _customer_id, _address]]}} ->
        Estimate.load_booking(booking_id)

      {:ok, _} ->
        {:error, {:status, 404, %{error: "Booking not found"}}}

      {:error, _} ->
        {:error, {:status, 503, %{error: "Booking authorization unavailable"}}}
    end
  end

  defp booking_destination(booking) do
    case Origins.load_booking_destination_strict(booking) do
      {:ok, destination} -> {:ok, destination}
      _ -> {:error, {:status, 422, %{error: "Booking destination is unavailable"}}}
    end
  end

  defp ensure_gate do
    case Repo.query(
           "SELECT enabled FROM public.app_feature_flags WHERE key = 'BOOKING_UBER_TRANSPORTATION' AND channel = 'production'",
           []
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, _} -> {:error, {:status, 409, %{error: "Transport is disabled"}}}
      {:error, _} -> {:error, {:status, 503, %{error: "Transport flag unavailable"}}}
    end
  end

  # Bound the number of saved quotes per customer before the paid routing API.
  defp enforce_limit(user_id) do
    case Repo.query(
           """
           SELECT count(*) FROM public.uber_transportation_quotes
           WHERE customer_id = $1::uuid AND revoked_at IS NULL AND expires_at > now()
           """,
           [DbUuid.dump!(user_id)]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count < 5 -> :ok
      {:ok, _} -> {:error, {:status, 429, %{error: "Too many active transport quotes"}}}
      {:error, _} -> {:error, {:status, 503, %{error: "Transport quote limit unavailable"}}}
    end
  end

  defp strict_price(distance_km) do
    case Pricing.quote_strict(distance_km) do
      {:ok, priced} -> {:ok, priced}
      {:error, _} -> {:error, {:status, 503, %{error: "Transport pricing unavailable"}}}
    end
  end

  defp load_origin(cleaner_id) do
    case Origins.load_cleaner_origin_strict(cleaner_id) do
      {:ok, origin} ->
        {:ok, origin}

      _ ->
        {:error,
         {:status, 422,
          %{error: "Cleaner location is not available", code: "cleaner_location_missing"}}}
    end
  end

  defp route(origin, dest) do
    case Router.directions(origin, dest) do
      {:ok, %{distance_m: distance_m, duration_s: duration_s}} when is_number(distance_m) ->
        {:ok,
         %{
           distance_km: distance_m / 1000.0,
           duration_seconds: max(0, trunc(duration_s))
         }}

      {:error, :not_configured} ->
        {:error, {:status, 500, %{error: "Transport routing is not configured"}}}

      {:error, :rate_limited} ->
        {:error, {:status, 429, %{error: "Too many transport estimates. Try again shortly."}}}

      _ ->
        {:error, {:status, 502, %{error: "Could not estimate transport"}}}
    end
  end

  defp ensure_priced(%{currency: "GHS", amount_minor: amount})
       when is_integer(amount) and amount > 0,
       do: :ok

  defp ensure_priced(_),
    do:
      {:error,
       {:status, 422,
        %{error: "Transport price is not available", code: "transport_price_unavailable"}}}

  defp insert_quote(user_id, cleaner_id, booking_id, token, latitude, longitude, route, priced) do
    expires_at = DateTime.utc_now() |> DateTime.add(@quote_ttl_seconds, :second)
    display = display(priced.amount_minor)

    sql = """
    INSERT INTO public.uber_transportation_quotes (
      customer_id, cleaner_id, amount_minor, currency, distance_km, duration_seconds,
      product_id, product_name, estimate_display, customer_latitude, customer_longitude, expires_at
    ) VALUES (
      $1::uuid, $2::uuid, $3, 'GHS', $4, $5,
      'instaclean', 'Instaclean transport', $6, $7, $8, $9::timestamptz
    )
    RETURNING id::text, expires_at
    """

    params = [
      DbUuid.dump!(user_id),
      DbUuid.dump!(cleaner_id),
      priced.amount_minor,
      route.distance_km,
      route.duration_seconds,
      display,
      latitude,
      longitude,
      DateTime.to_iso8601(expires_at)
    ]

    case Repo.transaction(fn ->
           case Repo.query(
                  "SELECT enabled FROM public.app_feature_flags WHERE key = 'BOOKING_UBER_TRANSPORTATION' AND channel = 'production' FOR UPDATE",
                  []
                ) do
             {:ok, %{rows: [[true]]}} ->
               with :ok <- enforce_limit(user_id),
                    :ok <- confirm_quote_subject(user_id, cleaner_id, booking_id) do
                 case Repo.query(sql, params) do
                   {:ok, %{rows: [[id, expires]]}} ->
                     case Repo.query(
                            "DELETE FROM public.transport_quote_reservations WHERE id = $1::uuid AND customer_id = $2::uuid",
                            [DbUuid.dump!(token), DbUuid.dump!(user_id)]
                          ) do
                       {:ok, %{num_rows: 1}} -> {id, expires}
                       _ -> Repo.rollback(:insert_failed)
                     end

                   _ ->
                     Repo.rollback(:insert_failed)
                 end
               else
                 {:error, :cleaner_unavailable} -> Repo.rollback(:cleaner_unavailable)
                 _ -> Repo.rollback(:invalid_booking_or_quota)
               end

             {:error, _} ->
               Repo.rollback(:gate_unavailable)

             _ ->
               Repo.rollback(:disabled)
           end
         end) do
      {:ok, {id, expires}} ->
        {:ok, %{id: id, expires_at: expires_iso(expires), display: display}}

      {:error, :disabled} ->
        {:error, {:status, 409, %{error: "Transport is disabled"}}}

      {:error, :gate_unavailable} ->
        {:error, {:status, 503, %{error: "Transport flag unavailable"}}}

      {:error, :invalid_booking_or_quota} ->
        {:error, {:status, 409, %{error: "Booking changed or quote limit reached"}}}

      {:error, :cleaner_unavailable} ->
        {:error, {:status, 404, %{error: "Cleaner not found"}}}

      _ ->
        {:error, {:status, 500, %{error: "Could not save the transport quote"}}}
    end
  end

  defp confirm_quote_subject(_user_id, cleaner_id, nil) do
    case authorize_cleaner(cleaner_id) do
      :ok -> :ok
      _ -> {:error, :cleaner_unavailable}
    end
  end

  defp confirm_quote_subject(user_id, cleaner_id, booking_id) when is_binary(booking_id) do
    case Repo.query(
           """
           SELECT 1 FROM public.bookings
           WHERE id = $1::uuid AND customer_id = $2::uuid AND cleaner_id = $3::uuid
             AND status IN ('pending', 'confirmed', 'scheduled', 'en_route', 'arrived', 'in_progress')
           FOR UPDATE
           """,
           [DbUuid.dump!(booking_id), DbUuid.dump!(user_id), DbUuid.dump!(cleaner_id)]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      _ -> {:error, :invalid_booking}
    end
  end

  # Distance and price only. The worker home used for routing is not returned.
  defp present(route, priced, quote) do
    fee_major = priced.amount_minor / 100

    Map.take(
      %{
        distance_km: Float.round(route.distance_km, 2),
        distance_miles: Float.round(route.distance_km / 1.609344, 2),
        duration_seconds: route.duration_seconds,
        currency_code: "GHS",
        estimate_display: quote.display,
        low_estimate_major: fee_major,
        high_estimate_major: fee_major,
        customer_fee_major: fee_major,
        quote_id: quote.id,
        quote_expires_at: quote.expires_at,
        product_id: "instaclean",
        product_name: "Instaclean transport"
      },
      [
        :distance_km,
        :distance_miles,
        :duration_seconds,
        :currency_code,
        :estimate_display,
        :low_estimate_major,
        :high_estimate_major,
        :customer_fee_major,
        :quote_id,
        :quote_expires_at,
        :product_id,
        :product_name
      ]
    )
  end

  defp display(amount_minor) do
    major = :erlang.float_to_binary(amount_minor / 100, decimals: 2)
    "GH₵#{major}"
  end

  defp expires_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp expires_iso(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp expires_iso(value) when is_binary(value), do: value
  defp expires_iso(value), do: to_string(value)
end
