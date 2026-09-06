defmodule Mithril.DirectPaymentsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectPayments
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    Application.put_env(:mithril, :paystack_test_attempts, %{})
    create_payment_tables!()
    :ok
  end

  test "initializes Paystack checkout from the stored booking amount" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)

    assert {:ok, checkout} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
             })

    assert checkout.amountMinor == 19_350
    assert checkout.currency == "GHS"
    assert checkout.paymentStatus == "pending"
    assert String.starts_with?(checkout.authorizationUrl, "https://checkout.paystack.com/")
    assert checkout.reference
  end

  test "rejects a callback URL that is not the booking confirmation page" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)

    assert {:error, :invalid_callback_url} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://evil.example/steal"
             })
  end

  test "verifies a successful Paystack payment against the snapshot" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)

    {:ok, checkout} =
      DirectPayments.initialize(customer_id, booking_id, %{
        "callbackUrl" => "http://localhost:3000/bookings/#{booking_id}"
      })

    assert {:ok, paid} =
             DirectPayments.verify(customer_id, booking_id, %{"reference" => checkout.reference})

    assert paid.paymentStatus == "paid"
    assert paid.amountMinor == 19_350

    [[payment_status, payment_method]] =
      Repo.query!(
        "SELECT payment_status, payment_method FROM public.bookings WHERE id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert payment_status == "paid"
    assert payment_method == "paystack"
  end

  test "does not mark paid when Paystack amount does not match the booking" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)

    {:ok, checkout} =
      DirectPayments.initialize(customer_id, booking_id, %{
        "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
      })

    Mithril.Paystack.Test.put_attempt(checkout.reference, %{
      status: "success",
      amount: 1,
      currency: "GHS",
      reference: checkout.reference
    })

    assert {:error, :amount_mismatch} =
             DirectPayments.verify(customer_id, booking_id, %{"reference" => checkout.reference})
  end

  defp insert_booking!(customer_id, amount_minor) do
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.users (id, email, status)
      VALUES ($1, 'customer@example.com', 'active')
      ON CONFLICT (id) DO NOTHING
      """,
      [Ecto.UUID.dump!(customer_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, payment_status, final_amount_minor, total_price, currency
      ) VALUES ($1, $2, 'pending', $3::bigint, $4::numeric, 'GHS')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), amount_minor, amount_minor]
    )

    booking_id
  end

  defp create_payment_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate payment fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.payment_attempts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.reserve_booking_payment_attempt(uuid, text, bigint, text)"
    )

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.complete_booking_payment_attempt(uuid, text, text, text)"
    )

    Repo.query!("DROP FUNCTION IF EXISTS public.fail_booking_payment_attempt(uuid, text)")

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text,
      status text NOT NULL DEFAULT 'active'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      payment_status text NOT NULL DEFAULT 'pending',
      payment_method text,
      reference text,
      final_amount_minor bigint NOT NULL,
      total_price numeric,
      currency text NOT NULL DEFAULT 'GHS',
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payment_attempts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
      provider text NOT NULL DEFAULT 'paystack',
      reference text NOT NULL UNIQUE,
      request_fingerprint text NOT NULL,
      status text NOT NULL DEFAULT 'initializing',
      amount_minor bigint NOT NULL,
      currency text NOT NULL,
      authorization_url text,
      access_code text,
      failure_reason text,
      expires_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      ready_at timestamptz,
      paid_at timestamptz,
      failed_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE FUNCTION public.reserve_booking_payment_attempt(
      p_booking_id uuid,
      p_request_fingerprint text,
      p_amount_minor bigint,
      p_currency text
    )
    RETURNS TABLE(
      attempt_id uuid,
      created boolean,
      state text,
      reference text,
      authorization_url text,
      access_code text,
      payment_status text,
      expires_at timestamptz,
      amount_minor bigint,
      currency text,
      request_fingerprint text
    )
    LANGUAGE plpgsql AS $fn$
    DECLARE
      v_attempt public.payment_attempts%ROWTYPE;
      v_payment_status text;
      v_new_id uuid := gen_random_uuid();
      v_reference text;
    BEGIN
      SELECT b.payment_status INTO v_payment_status
      FROM public.bookings b WHERE b.id = p_booking_id;

      IF NOT FOUND THEN
        RETURN;
      END IF;

      SELECT pa.* INTO v_attempt
      FROM public.payment_attempts pa
      WHERE pa.booking_id = p_booking_id
        AND pa.status IN ('initializing', 'ready')
      ORDER BY pa.created_at DESC
      LIMIT 1;

      IF FOUND THEN
        attempt_id := v_attempt.id;
        created := false;
        state := v_attempt.status;
        reference := v_attempt.reference;
        authorization_url := v_attempt.authorization_url;
        access_code := v_attempt.access_code;
        payment_status := v_payment_status;
        expires_at := v_attempt.expires_at;
        amount_minor := v_attempt.amount_minor;
        currency := v_attempt.currency;
        request_fingerprint := v_attempt.request_fingerprint;
        RETURN NEXT;
        RETURN;
      END IF;

      v_reference := format('BK-%s-%s', p_booking_id::text, left(replace(v_new_id::text, '-', ''), 8));

      INSERT INTO public.payment_attempts (
        id, booking_id, reference, request_fingerprint, status, amount_minor, currency, expires_at
      ) VALUES (
        v_new_id, p_booking_id, v_reference, p_request_fingerprint, 'initializing',
        p_amount_minor, p_currency, now() + interval '5 minutes'
      ) RETURNING * INTO v_attempt;

      UPDATE public.bookings SET reference = v_attempt.reference, updated_at = now()
      WHERE id = p_booking_id;

      attempt_id := v_attempt.id;
      created := true;
      state := v_attempt.status;
      reference := v_attempt.reference;
      authorization_url := NULL;
      access_code := NULL;
      payment_status := v_payment_status;
      expires_at := v_attempt.expires_at;
      amount_minor := v_attempt.amount_minor;
      currency := v_attempt.currency;
      request_fingerprint := v_attempt.request_fingerprint;
      RETURN NEXT;
    END;
    $fn$;
    """)

    Repo.query!("""
    CREATE FUNCTION public.complete_booking_payment_attempt(
      p_attempt_id uuid,
      p_authorization_url text,
      p_access_code text,
      p_provider_reference text
    )
    RETURNS TABLE(
      state text,
      reference text,
      authorization_url text,
      access_code text,
      payment_status text
    )
    LANGUAGE plpgsql AS $fn$
    DECLARE
      v_attempt public.payment_attempts%ROWTYPE;
      v_payment_status text;
    BEGIN
      UPDATE public.payment_attempts
      SET status = 'ready',
          authorization_url = p_authorization_url,
          access_code = p_access_code,
          ready_at = now(),
          updated_at = now()
      WHERE id = p_attempt_id
      RETURNING * INTO v_attempt;

      SELECT b.payment_status INTO v_payment_status
      FROM public.bookings b WHERE b.id = v_attempt.booking_id;

      state := 'ready';
      reference := v_attempt.reference;
      authorization_url := v_attempt.authorization_url;
      access_code := v_attempt.access_code;
      payment_status := v_payment_status;
      RETURN NEXT;
    END;
    $fn$;
    """)

    Repo.query!("""
    CREATE FUNCTION public.fail_booking_payment_attempt(p_attempt_id uuid, p_failure_reason text)
    RETURNS boolean
    LANGUAGE plpgsql AS $fn$
    BEGIN
      UPDATE public.payment_attempts
      SET status = 'failed', failure_reason = p_failure_reason, failed_at = now(), updated_at = now()
      WHERE id = p_attempt_id;
      RETURN true;
    END;
    $fn$;
    """)
  end
end
