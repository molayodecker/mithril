defmodule Mithril.Repo.Migrations.AddBookingMilestoneNotifications do
  use Ecto.Migration

  def change do
    create table(:booking_milestone_notifications, primary_key: false) do
      add :booking_id, :uuid, null: false
      add :milestone, :text, null: false
      add :cleaner_id, :uuid, null: false
      add :customer_id, :uuid, null: false
      add :status, :text, null: false, default: "pending"
      add :delivered_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create unique_index(:booking_milestone_notifications, [:booking_id, :milestone],
             name: :booking_milestone_notifications_booking_milestone_idx
           )

    create constraint(
             :booking_milestone_notifications,
             :booking_milestone_notifications_milestone_check,
             check: "milestone IN ('cleaner_en_route', 'cleaner_arrived')"
           )

    create constraint(
             :booking_milestone_notifications,
             :booking_milestone_notifications_status_check,
             check: "status IN ('pending', 'delivered')"
           )
  end
end
