defmodule Mithril.Transport.Estimate do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.Transport.Origins
  alias Mithril.Transport.Pricing
  alias Mithril.Transport.Router
  alias Mithril.Transport.UberHandoff

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @active_statuses ~w(pending confirmed scheduled en_route arrived in_progress)

  @spec for_booking(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def for_booking(user_id, booking_id) when is_binary(user_id) and is_binary(booking_id) do
    booking_id = String.trim(booking_id)

    cond do
      not Regex.match?(@uuid_regex, booking_id) ->
        {:error, {:status, 400, %{error: "Invalid booking id"}}}

      true ->
        with {:ok, booking} <- load_booking(booking_id),
             :ok <- authorize(user_id, booking),
             :ok <- ensure_assigned(booking),
             {:ok, origin} <- load_origin(booking),
             {:ok, dest} <- load_destination(booking),
             {:ok, route} <- route(origin, dest),
             {:ok, priced} <- Pricing.quote(route.distance_km) do
          {:ok, present(user_id, booking, route, priced, origin, dest)}
        end
    end
  end

  defp load_booking(booking_id) do
    sql = """
    SELECT id, customer_id, cleaner_id, status, address
    FROM public.bookings
    WHERE id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [booking_id]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, Map.new(Enum.zip(columns, row))}
      {:ok, %{rows: []}} -> {:error, {:status, 404, %{error: "Booking not found"}}}
      _ -> {:error, {:status, 404, %{error: "Booking not found"}}}
    end
  end

  defp authorize(user_id, booking) do
    if user_id in [Map.get(booking, "customer_id"), Map.get(booking, "cleaner_id")] do
      :ok
    else
      {:error, {:status, 403, %{error: "Forbidden"}}}
    end
  end

  defp ensure_assigned(booking) do
    cleaner_id = Map.get(booking, "cleaner_id")
    status = booking |> Map.get("status") |> to_string() |> String.downcase()

    cond do
      is_nil(cleaner_id) or cleaner_id == "" ->
        {:error, {:status, 409, %{error: "No assigned cleaner", code: "no_assigned_cleaner"}}}

      status not in @active_statuses ->
        {:error, {:status, 409, %{error: "Booking is not active", code: "booking_not_active"}}}

      true ->
        :ok
    end
  end

  defp load_destination(booking) do
    case Origins.load_booking_destination(booking) do
      {:ok, dest} ->
        {:ok, dest}

      _ ->
        {:error,
         {:status, 422,
          %{error: "Booking destination is not available", code: "destination_missing"}}}
    end
  end

  defp load_origin(booking) do
    case Origins.load_cleaner_origin(Map.get(booking, "cleaner_id")) do
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
      {:ok, %{distance_m: distance_m, duration_s: duration_s}} ->
        {:ok,
         %{
           distance_km: Float.round(distance_m / 1000.0, 2),
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

  defp present(user_id, booking, route, priced, origin, dest) do
    %{
      bookingId: Map.get(booking, "id"),
      distanceKm: route.distance_km,
      durationSeconds: route.duration_seconds,
      durationLabel: duration_label(route.duration_seconds),
      amountMinor: priced.amount_minor,
      currency: priced.currency,
      display: display(priced),
      provider: "locationiq",
      uberHandoffUrl: UberHandoff.maybe_url(user_id, booking, origin, dest)
    }
  end

  defp duration_label(seconds) when is_integer(seconds) and seconds > 0 do
    minutes = max(1, round(seconds / 60))
    "~#{minutes} min"
  end

  defp duration_label(_), do: nil

  defp display(%{currency: "GHS", amount_minor: amount}) do
    major = :erlang.float_to_binary(amount / 100, decimals: 2)
    "Estimated transport: GH₵#{major}"
  end

  defp display(%{currency: currency, amount_minor: amount}) do
    major = :erlang.float_to_binary(amount / 100, decimals: 2)
    "Estimated transport: #{currency} #{major}"
  end
end
