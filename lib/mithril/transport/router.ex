defmodule Mithril.Transport.Router do
  @moduledoc false

  @type coord :: %{latitude: float(), longitude: float()}
  @type route :: %{distance_m: float(), duration_s: float()}

  @callback directions(coord(), coord()) :: {:ok, route()} | {:error, term()}
  @callback matrix([coord()], coord()) :: {:ok, [route()]} | {:error, term()}
  @callback geocode(String.t()) :: {:ok, coord()} | {:error, term()}

  def directions(from, to), do: impl().directions(from, to)
  def matrix(sources, dest), do: impl().matrix(sources, dest)
  def geocode(address), do: impl().geocode(address)

  defp impl do
    Application.get_env(:mithril, :transport_router, Mithril.Transport.Router.LocationIQ)
  end
end
