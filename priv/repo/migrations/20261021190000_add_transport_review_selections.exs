defmodule Mithril.Repo.Migrations.AddTransportReviewSelections do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE IF NOT EXISTS public.transport_review_selections (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        customer_id uuid NOT NULL,
        cleaner_id uuid NOT NULL,
        latitude double precision NOT NULL,
        longitude double precision NOT NULL,
        expires_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        UNIQUE (customer_id, cleaner_id)
      )
      """,
      "DROP TABLE IF EXISTS public.transport_review_selections"
    )

    execute(
      """
      CREATE INDEX IF NOT EXISTS transport_review_selections_customer_expiry_idx
        ON public.transport_review_selections (customer_id, expires_at)
      """,
      "DROP INDEX IF EXISTS public.transport_review_selections_customer_expiry_idx"
    )
  end
end
