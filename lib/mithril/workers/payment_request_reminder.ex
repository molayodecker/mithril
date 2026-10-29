defmodule Mithril.Workers.PaymentRequestReminder do
  @moduledoc false

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 8,
    unique: [
      period: 60 * 60 * 24 * 120,
      fields: [:worker, :args],
      keys: [:payment_request_id, :step],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Mithril.DirectPaymentRequests

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payment_request_id" => id, "step" => step}})
      when is_binary(id) and is_integer(step) do
    case DirectPaymentRequests.deliver_unpaid_reminder(id, step) do
      :ok -> :ok
      {:snooze, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_), do: :discard
end
