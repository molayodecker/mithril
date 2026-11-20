defmodule Mithril.WorkerIdPass.PushListener do
  @moduledoc """
  Wakes an installed Wallet pass as soon as a status trigger commits.

  The database notification is not durable. `worker_id_passes.push_pending`
  and the minute sweep still retry when this process is down or Apple
  rejects the push.
  """

  use GenServer

  require Logger

  alias Mithril.WorkerIdPass

  @channel "worker_id_pass_push"
  @retry_ms 5_000

  @spec channel() :: String.t()
  def channel, do: @channel

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    send(self(), :listen)
    {:ok, %{notifications: nil, ref: nil, retry_ms: Keyword.get(opts, :retry_ms, @retry_ms)}}
  end

  @impl true
  def handle_info(:listen, state) do
    case listen() do
      {:ok, pid, ref} ->
        Process.monitor(pid)
        {:noreply, %{state | notifications: pid, ref: ref}}

      {:error, reason} ->
        Logger.warning("worker id pass listener could not connect: #{disconnect_reason(reason)}")
        Process.send_after(self(), :listen, state.retry_ms)
        {:noreply, %{state | notifications: nil, ref: nil}}
    end
  end

  def handle_info({:notification, _pid, ref, @channel, _payload}, %{ref: ref} = state) do
    flush()
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor, :process, pid, reason}, %{notifications: pid} = state) do
    Logger.warning("worker id pass listener disconnected: #{disconnect_reason(reason)}")
    Process.send_after(self(), :listen, state.retry_ms)
    {:noreply, %{state | notifications: nil, ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp flush do
    WorkerIdPass.flush_pending_pushes()
  rescue
    error ->
      Logger.warning("worker id pass push flush failed: #{Exception.message(error)}")
  end

  defp listen do
    opts = [sync_connect: true] ++ notification_opts()

    case Postgrex.Notifications.start_link(opts) do
      {:ok, pid} ->
        case Postgrex.Notifications.listen(pid, @channel) do
          {:ok, ref} ->
            {:ok, pid, ref}

          {:error, reason} ->
            Process.unlink(pid)
            Process.exit(pid, :shutdown)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp disconnect_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp disconnect_reason(%{message: message}) when is_binary(message), do: message
  defp disconnect_reason(_reason), do: "connection closed"

  defp notification_opts do
    Mithril.Repo.config()
    |> Keyword.take([
      :hostname,
      :port,
      :database,
      :username,
      :password,
      :ssl,
      :socket,
      :socket_options,
      :parameters
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
