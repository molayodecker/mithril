defmodule Mithril.Transport.UberHandoff do
  @moduledoc false

  @handoff_statuses ~w(confirmed scheduled en_route arrived in_progress)

  def maybe_url(user_id, booking, origin, dest) do
    if user_id == Map.get(booking, "cleaner_id") and
         status(booking) in @handoff_statuses do
      url(origin, dest, Map.get(booking, "address"))
    else
      nil
    end
  end

  def url(origin, dest, dropoff_label \\ nil) do
    pickup = Jason.encode!(%{latitude: origin.latitude, longitude: origin.longitude})

    drop =
      %{latitude: dest.latitude, longitude: dest.longitude}
      |> maybe_put_address(dropoff_label)
      |> Jason.encode!()

    query =
      %{"pickup" => pickup, "drop[0]" => drop}
      |> maybe_put_client_id()
      |> URI.encode_query()

    "https://m.uber.com/looking?" <> query
  end

  defp maybe_put_address(drop, label) when is_binary(label) do
    trimmed = String.trim(label)
    if trimmed == "", do: drop, else: Map.put(drop, :addressLine1, String.slice(trimmed, 0, 120))
  end

  defp maybe_put_address(drop, _), do: drop

  defp maybe_put_client_id(query) do
    case Application.get_env(:mithril, :uber_client_id) do
      id when is_binary(id) and id != "" -> Map.put(query, "client_id", id)
      _ -> query
    end
  end

  defp status(booking) do
    booking |> Map.get("status") |> to_string() |> String.downcase()
  end
end
