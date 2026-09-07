defmodule Mithril.DirectPaymentsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectPayments
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    Application.put_env(:mithril, :paystack_test_attempts, %{})
    Application.put_env(:mithril, :direct_payment_poll_delays_ms, [0, 0])
    create_payment_tables!()

    on_exit(fn ->
      Application.delete_env(:mithril, :direct_payment_poll_delays_ms)
      Application.delete_env(:mithril, :paystack_tax_subaccount)
      Application.delete_env(:mithril, :paystack_vendor_subaccount)
      Application.put_env(:mithril, :paystack_test_attempts, %{})
    end)

    :ok
  end

  test "initializes Paystack checkout from the canonical payable snapshot" do
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

    assert {:ok, receipt} = Mithril.Paystack.verify(checkout.reference)
    assert receipt.split_code == "SPL_test"
  end

  test "uses numeric shares for dynamic Paystack split routing" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)

    Repo.query!(
      """
      UPDATE public.bookings
      SET paystack_split_code = NULL,
          tax_share_minor = 1_000,
          vendor_share_minor = 2_000
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(booking_id)]
    )

    Application.put_env(:mithril, :paystack_tax_subaccount, "ACCT_tax")
    Application.put_env(:mithril, :paystack_vendor_subaccount, "ACCT_vendor")

    assert {:ok, checkout} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
             })

    assert {:ok, receipt} = Mithril.Paystack.verify(checkout.reference)
    assert %{subaccounts: [tax, vendor]} = receipt.split
    assert tax == %{subaccount: "ACCT_tax", share: 1_000}
    assert vendor == %{subaccount: "ACCT_vendor", share: 2_000}
  end

  test "rejects a callback URL that is not the booking confirmation page" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)

    assert {:error, :invalid_callback_url} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://evil.example/steal"
             })
  end

  test "verifies a successful Paystack payment against its reserved attempt" do
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

  test "does not mark paid when Paystack amount does not match the reserved attempt" do
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

  test "cannot reuse a successful reference from another booking" do
    customer_id = Ecto.UUID.generate()
    first_booking = insert_booking!(customer_id, 19_350)
    second_booking = insert_booking!(customer_id, 19_350)

    {:ok, first_checkout} =
      DirectPayments.initialize(customer_id, first_booking, %{
        "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{first_booking}"
      })

    {:ok, _second_checkout} =
      DirectPayments.initialize(customer_id, second_booking, %{
        "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{second_booking}"
      })

    assert {:error, :payment_reference_mismatch} =
             DirectPayments.verify(customer_id, second_booking, %{
               "reference" => first_checkout.reference
             })

    assert [["pending"]] =
             Repo.query!(
               "SELECT payment_status FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(second_booking)]
             ).rows
  end

  test "does not initialize Paystack when another request owns the attempt" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)
    attempt = reserve_raw_attempt!(booking_id, 19_350)

    assert attempt.created

    assert {:error, :payment_in_progress} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
             })

    assert {:error, :not_found} = Mithril.Paystack.verify(attempt.reference)

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM public.payment_attempts WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "verifies a stale missing reference before rotating it" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)
    stale = reserve_raw_attempt!(booking_id, 19_350)

    expire_attempt!(stale.attempt_id)

    assert {:ok, checkout} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
             })

    refute checkout.reference == stale.reference
    assert attempt_status(stale.attempt_id) == "failed"
  end

  test "rotates a stale attempt after Paystack reports a terminal failure" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)
    stale = reserve_raw_attempt!(booking_id, 19_350)

    expire_attempt!(stale.attempt_id)

    Mithril.Paystack.Test.put_attempt(stale.reference, %{
      status: "failed",
      amount: 19_350,
      currency: "GHS",
      reference: stale.reference
    })

    assert {:ok, checkout} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
             })

    refute checkout.reference == stale.reference
    assert attempt_status(stale.attempt_id) == "failed"
  end

  test "keeps a stale attempt reserved while Paystack reports a pending state" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)
    stale = reserve_raw_attempt!(booking_id, 19_350)

    expire_attempt!(stale.attempt_id)

    Mithril.Paystack.Test.put_attempt(stale.reference, %{
      status: "pending",
      amount: 19_350,
      currency: "GHS",
      reference: stale.reference
    })

    assert {:error, :payment_in_progress} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
             })

    assert attempt_status(stale.attempt_id) == "initializing"

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM public.payment_attempts WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "canonical payable snapshot blocks non-payable bookings" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, 19_350)

    Repo.query!("UPDATE public.bookings SET status = 'cancelled' WHERE id = $1", [
      Ecto.UUID.dump!(booking_id)
    ])

    assert {:error, :payment_not_payable} =
             DirectPayments.initialize(customer_id, booking_id, %{
               "callbackUrl" => "https://direct.tryinstaclean.com/bookings/#{booking_id}"
             })
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
        id, customer_id, service_id, status, payment_status,
        final_amount_minor, total_price, currency,
        payment_split_type, paystack_split_code
      ) VALUES ($1, $2, 1, 'pending', 'pending', $3::bigint, $4::numeric, 'GHS',
                'split_code', 'SPL_test')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), amount_minor, amount_minor]
    )

    booking_id
  end

  defp reserve_raw_attempt!(booking_id, amount_minor) do
    fingerprint = "direct:#{booking_id}:#{amount_minor}:GHS"

    [
      [
        attempt_id,
        created,
        state,
        reference,
        _authorization_url,
        _access_code,
        _payment_status,
        _expires_at,
        _reserved_amount,
        _currency,
        _request_fingerprint
      ]
    ] =
      Repo.query!(
        """
        SELECT attempt_id, created, state, reference, authorization_url, access_code,
               payment_status, expires_at, amount_minor, currency, request_fingerprint
        FROM public.reserve_booking_payment_attempt($1::uuid, $2::text, $3::bigint, 'GHS')
        """,
        [Ecto.UUID.dump!(booking_id), fingerprint, amount_minor]
      ).rows

    %{attempt_id: attempt_id, created: created, state: state, reference: reference}
  end

  defp expire_attempt!(attempt_id) do
    Repo.query!(
      "UPDATE public.payment_attempts SET expires_at = now() - interval '1 minute' WHERE id = $1",
      [attempt_id]
    )
  end

  defp attempt_status(attempt_id) do
    [[status]] =
      Repo.query!("SELECT status FROM public.payment_attempts WHERE id = $1", [attempt_id]).rows

    status
  end

  defp create_payment_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate payment fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.payment_attempts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.service_types CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.reserve_booking_payment_attempt(uuid, text, bigint, text)"
    )

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.complete_booking_payment_attempt(uuid, text, text, text)"
    )

    Repo.query!("DROP FUNCTION IF EXISTS public.fail_booking_payment_attempt(uuid, text)")
    Repo.query!("DROP FUNCTION IF EXISTS public.get_payable_booking_snapshot(uuid)")

    Repo.query!("CREATE SCHEMA IF NOT EXISTS auth")

    Repo.query!("""
    CREATE OR REPLACE FUNCTION auth.uid()
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $fn$
      SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
    $fn$
    """)

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text,
      status text NOT NULL DEFAULT 'active'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_types (
      id integer PRIMARY KEY,
      specialty_slug text NOT NULL
    )
    """)

    Repo.query!(
      "INSERT INTO public.service_types (id, specialty_slug) VALUES (1, 'regular_cleaning')"
    )

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      service_id integer NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      payment_status text NOT NULL DEFAULT 'pending',
      payment_method text,
      reference text,
      final_amount_minor bigint NOT NULL,
      total_price numeric,
      currency text NOT NULL DEFAULT 'GHS',
      payment_split_type text,
      paystack_split_code text,
      tax_share_minor integer,
      vendor_share_minor integer,
      platform_share_minor integer,
      tax_percentage_bps integer,
      vendor_percentage_bps integer,
      tax_paystack_share text,
      vendor_paystack_share text,
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
    CREATE FUNCTION public.get_payable_booking_snapshot(p_booking_id uuid)
    RETURNS TABLE(
      booking_id uuid,
      customer_id uuid,
      final_amount_minor integer,
      currency text,
      payment_status text,
      booking_status text,
      payment_reference text,
      payment_split_type text,
      paystack_split_code text,
      tax_share_minor integer,
      vendor_share_minor integer,
      platform_share_minor integer,
      tax_percentage_bps integer,
      vendor_percentage_bps integer,
      tax_paystack_share text,
      vendor_paystack_share text
    )
    LANGUAGE sql STABLE AS $fn$
      SELECT b.id,
             b.customer_id,
             b.final_amount_minor::integer,
             b.currency,
             b.payment_status,
             b.status,
             b.reference,
             b.payment_split_type,
             b.paystack_split_code,
             b.tax_share_minor,
             b.vendor_share_minor,
             b.platform_share_minor,
             b.tax_percentage_bps,
             b.vendor_percentage_bps,
             b.tax_paystack_share,
             b.vendor_paystack_share
      FROM public.bookings b
      WHERE b.id = p_booking_id
        AND b.customer_id = auth.uid()
        AND b.status = 'pending'
        AND lower(coalesce(b.payment_status, '')) IN ('pending', 'failed')
        AND b.final_amount_minor > 0
      LIMIT 1
    $fn$
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

      IF lower(coalesce(v_payment_status, '')) IN ('paid', 'post_paid', 'refunded', 'partially_refunded') THEN
        attempt_id := NULL;
        created := false;
        state := 'settled';
        reference := (SELECT b.reference FROM public.bookings b WHERE b.id = p_booking_id);
        payment_status := v_payment_status;
        RETURN NEXT;
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
        state := CASE
          WHEN v_attempt.status = 'initializing' AND v_attempt.expires_at <= now() THEN 'stale'
          ELSE v_attempt.status
        END;
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
        p_amount_minor, upper(p_currency), now() + interval '5 minutes'
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
      RETURN FOUND;
    END;
    $fn$;
    """)
  end
end
