defmodule Mithril.RateLimiter do
  @moduledoc false

  use GenServer

  @type key :: term()
  @cleanup_interval_ms 300_000
  @retention_ms 900_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec check(key(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def check(key, limit, window_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    GenServer.call(__MODULE__, {:check, key, limit, window_ms})
  end

  @impl true
  def init(_state) do
    schedule_cleanup()
    {:ok, %{}}
  end

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

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = System.monotonic_time(:millisecond) - @retention_ms

    pruned =
      Enum.reduce(state, %{}, fn {key, timestamps}, acc ->
        recent = Enum.filter(timestamps, &(&1 > cutoff))
        if recent == [], do: acc, else: Map.put(acc, key, recent)
      end)

    schedule_cleanup()
    {:noreply, pruned}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
