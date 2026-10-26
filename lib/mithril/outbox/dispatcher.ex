defmodule Mithril.Outbox.Dispatcher do
  @moduledoc false

  use GenServer

  alias Mithril.Outbox

  @interval 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:drain, %{interval: interval} = state) do
    Outbox.drain()
    schedule(interval)
    {:noreply, state}
  end

  defp schedule(interval) do
    Process.send_after(self(), :drain, interval)
  end
end
