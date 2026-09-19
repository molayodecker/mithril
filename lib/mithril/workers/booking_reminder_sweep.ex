defmodule Mithril.Workers.BookingReminderSweep do
  @moduledoc false

  use Oban.Worker, queue: :notifications, max_attempts: 1, unique: [period: 50]

  alias Mithril.Notifications.Reminders

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Reminders.enqueue_due()
  end
end
