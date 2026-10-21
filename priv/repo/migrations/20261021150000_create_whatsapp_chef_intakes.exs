defmodule Mithril.Repo.Migrations.CreateWhatsAppChefIntakes do
  use Ecto.Migration

  def change do
    create table(:whatsapp_chef_intakes, primary_key: false, prefix: "public") do
      add :phone, :text, primary_key: true
      add :step, :integer, null: false, default: 0
      add :status, :text, null: false, default: "in_progress"
      add :answers, :map, null: false, default: %{}
      add :last_message_sid, :text
      add :submitted_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create constraint(:whatsapp_chef_intakes, :chef_intake_status_check,
      check: "status IN ('in_progress', 'confirm', 'completed', 'paused')", prefix: "public")

    create constraint(:whatsapp_chef_intakes, :chef_intake_step_check,
      check: "step BETWEEN 0 AND 8", prefix: "public")

    create index(:whatsapp_chef_intakes, [:status, :updated_at], prefix: "public")

    create table(:whatsapp_chef_processed_messages, primary_key: false, prefix: "public") do
      add :message_sid, :text, primary_key: true
      add :phone, :text, null: false
      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:whatsapp_chef_processed_messages, [:phone], prefix: "public")

    create table(:whatsapp_chef_completed_enquiries, prefix: "public") do
      add :phone, :text, null: false
      add :answers, :map, null: false
      add :submitted_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:whatsapp_chef_completed_enquiries, [:submitted_at], prefix: "public")
  end
end
