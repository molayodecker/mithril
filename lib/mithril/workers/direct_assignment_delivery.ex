defmodule Mithril.Workers.DirectAssignmentDelivery do
  @moduledoc false

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 10,
    unique: [
      period: 86_400,
      keys: [:booking_id],
      states: [:available, :scheduled, :retryable, :executing]
    ]

  alias Mithril.DirectAssignmentNotify

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_id" => booking_id}}) do
    case DirectAssignmentNotify.deliver_pending(booking_id) do
      :sent -> :ok
      :skipped -> :ok
      :failed -> {:error, :delivery_failed}
    end
  end

  def perform(_), do: :discard
end
