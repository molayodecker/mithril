defmodule Mithril.StripeBookingPaymentAttemptReserveTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_tables!()
    create_reserve_function!()
    create_complete_function!()
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

  test "rejects an outdated snapshot after booking repricing without inserting an attempt" do
    booking_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO public.bookings (id, customer_id, final_amount_minor, currency) VALUES ($1, $2, 250, 'GHS')",
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id)]
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :invalid_parameter_value}}} =
             Repo.query(
               "SELECT * FROM public.reserve_booking_payment_attempt($1::uuid, 'old-price', 100, 'GHS', 'stripe')",
               [Ecto.UUID.dump!(booking_id)]
             )
  end

  test "retains PaymentIntent identity on an attempt invalidated during initialization" do
    booking_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    attempt_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO public.bookings (id, customer_id, final_amount_minor, currency) VALUES ($1, $2, 250, 'GHS')",
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.payment_attempts
        (id, booking_id, provider, reference, status, amount_minor, currency, expires_at)
      VALUES ($1, $2, 'stripe', 'BK-stale', 'failed', 100, 'GHS', now())
      """,
      [Ecto.UUID.dump!(attempt_id), Ecto.UUID.dump!(booking_id)]
    )

    assert %{rows: [["failed", "BK-stale", "pi_stale_123", nil, "pending"]]} =
             Repo.query!(
               """
               SELECT * FROM public.complete_stripe_booking_payment_attempt(
                 $1::uuid, 'pi_stale_123', 'pi_stale_123_secret', 'BK-stale'
               )
               """,
               [Ecto.UUID.dump!(attempt_id)]
             )

    assert %{rows: [["failed", "pi_stale_123"]]} =
             Repo.query!(
               "SELECT status, stripe_payment_intent_id FROM public.payment_attempts WHERE id = $1",
               [Ecto.UUID.dump!(attempt_id)]
             )
  end

  defp create_tables! do
    Repo.query!("DROP TABLE IF EXISTS public.payment_attempts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      payment_status text NOT NULL DEFAULT 'pending',
      status text NOT NULL DEFAULT 'pending',
      final_amount_minor bigint,
      total_price bigint,
      currency text,
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

  defp create_complete_function! do
    sql_path =
      Path.join([
        File.cwd!(),
        "priv/repo/sql/direct/20261117221500_stripe_booking_payment_attempts.sql"
      ])

    statement =
      sql_path
      |> File.read!()
      |> String.split("\\n-- %%\\n")
      |> Enum.find(
        &String.contains?(&1, "FUNCTION public.complete_stripe_booking_payment_attempt")
      )

    Repo.query!(String.trim(statement))
  end
end
