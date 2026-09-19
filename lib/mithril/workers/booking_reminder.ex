defmodule Mithril.Workers.BookingReminder do
  @moduledoc false

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: 3600, keys: [:booking_id, :stage]]

  alias Mithril.Notifications.Reminders

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_id" => booking_id, "stage" => stage}}) do
    case Reminders.send_stage(booking_id, stage) do
      :ok -> :ok
      :discard -> :discard
      {:error, :already_claimed} -> :discard
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: :discard
end
