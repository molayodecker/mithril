defmodule Mithril.Transport.Router.Stub do
  @moduledoc false

  @behaviour Mithril.Transport.Router

  @impl true
  def directions(_from, _to), do: {:ok, %{distance_m: 4200.0, duration_s: 780.0}}

  @impl true
  def matrix(sources, _dest) when is_list(sources) do
    {:ok, Enum.map(sources, fn _ -> %{distance_m: 4200.0, duration_s: 780.0} end)}
  end

  @impl true
  def geocode(address) when is_binary(address) and address != "" do
    {:ok, %{latitude: 5.65, longitude: -0.18}}
  end

  def geocode(_), do: {:error, :not_found}
end
