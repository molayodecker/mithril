defmodule Mithril.AdminBroadcast.WorkerSelection do
  @moduledoc false

  @pickable_statuses ~w(queued sending)
  @terminal_statuses ~w(completed failed)

  @spec pickable_status?(String.t()) :: boolean()
  def pickable_status?(status) when is_binary(status), do: status in @pickable_statuses
  def pickable_status?(_), do: false

  @spec terminal_status?(String.t()) :: boolean()
  def terminal_status?(status) when is_binary(status), do: status in @terminal_statuses
  def terminal_status?(_), do: false

  @spec worker_delivery_mode?(String.t()) :: boolean()
  def worker_delivery_mode?("worker"), do: true
  def worker_delivery_mode?(_), do: false

  @spec eligible_for_worker_pickup?(String.t(), String.t()) :: boolean()
  def eligible_for_worker_pickup?(delivery_mode, status) do
    worker_delivery_mode?(delivery_mode) and pickable_status?(status)
  end
end
