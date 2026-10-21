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
      check: "status IN ('in_progress', 'confirm', 'completed')", prefix: "public")

    create constraint(:whatsapp_chef_intakes, :chef_intake_step_check,
      check: "step BETWEEN 0 AND 8", prefix: "public")

    create index(:whatsapp_chef_intakes, [:status, :updated_at], prefix: "public")
  end
end
