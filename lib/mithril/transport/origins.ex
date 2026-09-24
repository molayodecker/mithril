defmodule Mithril.Transport.Origins do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Repo
  alias Mithril.Transport.Router

  def load_cleaner_origin(cleaner_id) when is_binary(cleaner_id) do
    case Repo.query("SELECT * FROM public.get_cleaner_trip_origin($1::uuid)", [
           DbUuid.dump!(cleaner_id)
         ]) do
      {:ok, %{columns: columns, rows: [row]}} ->
        coords_from_row(Map.new(Enum.zip(columns, row)))

      _ ->
        load_profile_origin(cleaner_id)
    end
  end

  def load_profile_origin(user_id) when is_binary(user_id) do
    postgis = """
    SELECT
      CASE WHEN location_wkt IS NULL THEN NULL ELSE ST_Y(location_wkt::geometry) END,
      CASE WHEN location_wkt IS NULL THEN NULL ELSE ST_X(location_wkt::geometry) END
    FROM public.profiles
    WHERE id = $1::uuid
    LIMIT 1
    """

    case Repo.query(postgis, [DbUuid.dump!(user_id)]) do
      {:ok, %{rows: [[lat, lng]]}} ->
        case coords(lat, lng) do
          {:ok, coord} -> {:ok, coord}
          :error -> {:error, :missing}
        end

      _ ->
        {:error, :missing}
    end
  end

  def load_booking_destination(booking) when is_map(booking) do
    cond do
      match?({:ok, _}, coords(Map.get(booking, "latitude"), Map.get(booking, "longitude"))) ->
        coords(Map.get(booking, "latitude"), Map.get(booking, "longitude"))

      match?({:ok, _}, coords(Map.get(booking, "lat"), Map.get(booking, "lng"))) ->
        coords(Map.get(booking, "lat"), Map.get(booking, "lng"))

      true ->
        case Router.geocode(Map.get(booking, "address") || "") do
          {:ok, coord} ->
            {:ok, coord}

          _ ->
            case load_profile_origin(Map.get(booking, "customer_id")) do
              {:ok, coord} -> {:ok, coord}
              _ -> {:error, :destination_missing}
            end
        end
    end
  end

  defp coords_from_row(row) do
    case coords(
           Map.get(row, "latitude") || Map.get(row, "lat"),
           Map.get(row, "longitude") || Map.get(row, "lng")
         ) do
      {:ok, coord} -> {:ok, coord}
      :error -> {:error, :missing}
    end
  end

  defp coords(lat, lng) do
    lat_f = to_float(lat)
    lng_f = to_float(lng)

    if is_number(lat_f) and is_number(lng_f) and lat_f >= -90 and lat_f <= 90 and lng_f >= -180 and
         lng_f <= 180 do
      {:ok, %{latitude: lat_f, longitude: lng_f}}
    else
      :error
    end
  end

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp to_float(_), do: nil
end
