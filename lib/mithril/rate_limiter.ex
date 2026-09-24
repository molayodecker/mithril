defmodule Mithril.RateLimiter do
  @moduledoc false

  use GenServer

  @type key :: term()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec check(key(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def check(key, limit, window_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    GenServer.call(__MODULE__, {:check, key, limit, window_ms})
  end

  @impl true
  def init(_state), do: {:ok, %{}}

  @impl true
  def handle_call({:check, key, limit, window_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    recent =
      state
      |> Map.get(key, [])
      |> Enum.filter(&(&1 > cutoff))

    if length(recent) >= limit do
      {:reply, {:error, :rate_limited}, Map.put(state, key, recent)}
    else
      updated = [now | recent]
      {:reply, :ok, Map.put(state, key, updated)}
    end
  end
end
