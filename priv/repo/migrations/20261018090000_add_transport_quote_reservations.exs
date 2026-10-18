defmodule Mithril.Repo.Migrations.AddTransportQuoteReservations do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE IF NOT EXISTS public.transport_quote_reservations (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        customer_id uuid NOT NULL,
        expires_at timestamptz NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS public.transport_quote_reservations"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS transport_quote_reservations_customer_idx ON public.transport_quote_reservations (customer_id, expires_at)",
      "DROP INDEX IF EXISTS public.transport_quote_reservations_customer_idx"
    )
  end
end
