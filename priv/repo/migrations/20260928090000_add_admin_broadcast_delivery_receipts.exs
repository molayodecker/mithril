defmodule Mithril.Repo.Migrations.AddAdminBroadcastDeliveryReceipts do
  use Ecto.Migration

  def change do
    create table(:admin_broadcast_delivery_receipts, primary_key: false) do
      add :broadcast_id, :uuid, null: false, primary_key: true
      add :user_id, :uuid, null: false, primary_key: true
      add :claimed_at, :utc_datetime_usec, null: false
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:admin_broadcast_delivery_receipts, [:broadcast_id, :delivered_at])
  end
end
