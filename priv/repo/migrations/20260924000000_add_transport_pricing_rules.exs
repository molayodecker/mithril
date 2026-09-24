defmodule Mithril.Repo.Migrations.AddTransportPricingRules do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS public.transport_pricing_rules (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      channel text NOT NULL DEFAULT 'production',
      currency text NOT NULL DEFAULT 'GHS',
      base_fee_minor integer NOT NULL DEFAULT 1000,
      per_km_rate_minor integer NOT NULL DEFAULT 350,
      min_fee_minor integer NOT NULL DEFAULT 1500,
      max_fee_minor integer NOT NULL DEFAULT 15000,
      bands jsonb NOT NULL DEFAULT '[]'::jsonb,
      enabled boolean NOT NULL DEFAULT true,
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT transport_pricing_rules_channel_key UNIQUE (channel),
      CONSTRAINT transport_pricing_rules_fees_nonneg CHECK (
        base_fee_minor >= 0
        AND per_km_rate_minor >= 0
        AND min_fee_minor >= 0
        AND max_fee_minor >= min_fee_minor
      )
    )
    """)

    execute("""
    INSERT INTO public.transport_pricing_rules (
      channel, currency, base_fee_minor, per_km_rate_minor, min_fee_minor, max_fee_minor, bands
    ) VALUES (
      'production',
      'GHS',
      1000,
      350,
      1500,
      15000,
      '[
        {"min_km": 0, "max_km": 3, "base_fee_minor": 1500, "per_km_rate_minor": 0},
        {"min_km": 3, "max_km": 10, "base_fee_minor": 1000, "per_km_rate_minor": 400},
        {"min_km": 10, "max_km": null, "base_fee_minor": 1000, "per_km_rate_minor": 300}
      ]'::jsonb
    )
    ON CONFLICT (channel) DO NOTHING
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS public.transport_pricing_rules")
  end
end
