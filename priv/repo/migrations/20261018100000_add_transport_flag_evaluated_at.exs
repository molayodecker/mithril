defmodule Mithril.Repo.Migrations.AddTransportFlagEvaluatedAt do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE public.app_feature_flags ADD COLUMN IF NOT EXISTS evaluated_at timestamptz",
      "ALTER TABLE public.app_feature_flags DROP COLUMN IF EXISTS evaluated_at"
    )
  end
end
