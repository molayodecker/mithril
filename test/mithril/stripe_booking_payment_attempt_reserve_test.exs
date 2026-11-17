defmodule Mithril.StripeBookingPaymentAttemptReserveTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_tables!()
    create_reserve_function!()
    :ok
  end

  test "returns no row and inserts nothing when the booking is missing" do
    missing_booking_id = Ecto.UUID.generate()

    assert %{num_rows: 0} =
             Repo.query!(
               """
               SELECT *
               FROM public.reserve_booking_payment_attempt($1::uuid, $2::text, $3::bigint, $4::text, 'stripe')
               """,
               [Ecto.UUID.dump!(missing_booking_id), "fingerprint", 100, "GHS"]
             )

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM public.payment_attempts")
  end

  defp create_tables! do
    Repo.query!("DROP TABLE IF EXISTS public.payment_attempts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      payment_status text NOT NULL DEFAULT 'pending',
      reference text,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payment_attempts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
      provider text NOT NULL,
      reference text NOT NULL,
      request_fingerprint text,
      status text NOT NULL,
      amount_minor bigint NOT NULL,
      currency text NOT NULL,
      authorization_url text,
      access_code text,
      stripe_payment_intent_id text,
      stripe_client_secret text,
      expires_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      failed_at timestamptz
    )
    """)
  end

  defp create_reserve_function! do
    sql_path =
      Path.join([
        File.cwd!(),
        "priv/repo/sql/direct/20261117221500_stripe_booking_payment_attempts.sql"
      ])

    statement =
      sql_path
      |> File.read!()
      |> String.split("\n-- %%\n")
      |> Enum.find(&String.contains?(&1, "FUNCTION public.reserve_booking_payment_attempt"))

    Repo.query!(String.trim(statement))
  end
end
