defmodule Mithril.DirectOperationsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectOperations
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate operations fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "direct_refund_requests",
          "booking_refunds",
          "bookings",
          "user_roles",
          "users"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("DROP FUNCTION IF EXISTS public.approve_cleaner_application(uuid)")

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      status text NOT NULL DEFAULT 'confirmed',
      payment_status text NOT NULL DEFAULT 'paid',
      subscription_id uuid,
      cleaner_id uuid,
      service_id integer,
      scheduled_date date NOT NULL,
      scheduled_time time NOT NULL,
      duration_hours numeric NOT NULL DEFAULT 2,
      timezone_name text,
      timezone text,
      final_amount_minor bigint,
      total_price bigint NOT NULL,
      currency text DEFAULT 'GHS',
      cancellation_tier text,
      cancelled_at timestamptz,
      cancelled_by uuid,
      cancelled_by_role text,
      cancellation_reason text,
      cancellation_reason_code text,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.booking_refunds (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL,
      refund_amount_minor bigint NOT NULL DEFAULT 0,
      status text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.direct_refund_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL,
      customer_id uuid NOT NULL,
      requested_by_user_id uuid NOT NULL,
      status text NOT NULL DEFAULT 'requested',
      reason text NOT NULL,
      policy_tier text,
      proposed_refund_percent integer,
      proposed_refund_amount_minor bigint,
      source text NOT NULL DEFAULT 'mcp',
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX direct_refund_requests_active_booking_uniq
      ON public.direct_refund_requests (booking_id)
      WHERE status IN ('requested', 'reviewing', 'approved', 'processing')
    """)

    :ok
  end

  test "partial refund policy proposes only the remaining policy amount" do
    customer_id = insert_user!("customer@example.com")
    booking_id = insert_booking!(customer_id, "partially_refunded", 10_000)

    Repo.query!(
      """
      INSERT INTO public.booking_refunds (booking_id, refund_amount_minor, status)
      VALUES ($1, 5000, 'processed')
      """,
      [Ecto.UUID.dump!(booking_id)]
    )

    assert {:ok, policy} = DirectOperations.cancellation_policy(customer_id, booking_id)
    assert policy.refundTier == "full_refund"
    assert policy.refundPercent == 100
    assert policy.alreadyRefundedAmountMinor == 5_000
    assert policy.refundAmountMinor == 5_000

    assert {:ok, request} =
             DirectOperations.request_refund(customer_id, booking_id, %{
               "reason" => "Please refund the remaining eligible balance"
             })

    assert request.status == "requested"

    [[percent, amount]] =
      Repo.query!(
        """
        SELECT proposed_refund_percent, proposed_refund_amount_minor
        FROM public.direct_refund_requests
        WHERE booking_id = $1
        """,
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert percent == 100
    assert amount == 5_000
  end

  test "partial refund already satisfying the policy does not queue another cancellation refund" do
    customer_id = insert_user!("customer@example.com")
    booking_id = insert_booking!(customer_id, "partially_refunded", 10_000, 1)

    Repo.query!(
      "UPDATE public.bookings SET cancellation_tier = 'partial_refund' WHERE id = $1",
      [Ecto.UUID.dump!(booking_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.booking_refunds (booking_id, refund_amount_minor, status)
      VALUES ($1, 5000, 'processed')
      """,
      [Ecto.UUID.dump!(booking_id)]
    )

    assert {:ok, policy} = DirectOperations.cancellation_policy(customer_id, booking_id)
    assert policy.refundTier == "partial_refund"
    assert policy.refundPercent == 50
    assert policy.refundAmountMinor == 0

    assert {:ok, cancelled} =
             DirectOperations.cancel_booking(customer_id, booking_id, %{
               "reason" => "Plans changed"
             })

    assert cancelled.status == "cancelled"
    assert cancelled.refundRequest == nil

    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM public.direct_refund_requests WHERE booking_id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert count == 0
  end

  test "cleaner approval maps application_not_found instead of returning database unavailable" do
    admin_id = insert_user!("ops@tryinstaclean.com")
    application_id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    Repo.query!("""
    CREATE FUNCTION public.approve_cleaner_application(uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'application_not_found';
    END;
    $$
    """)

    assert {:error, :application_not_found} =
             DirectOperations.approve_cleaner_application(admin_id, application_id)
  end

  defp insert_user!(email) do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.users (id, email) VALUES ($1, $2)", [
      Ecto.UUID.dump!(id),
      email
    ])

    id
  end

  defp insert_booking!(customer_id, payment_status, amount_minor, days_ahead \\ 2) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, status, payment_status, scheduled_date, scheduled_time,
        duration_hours, timezone_name, timezone, final_amount_minor, total_price, currency
      ) VALUES (
        $1, $2, 'confirmed', $3,
        (now() AT TIME ZONE 'Africa/Accra')::date + $4::integer,
        '10:00', 2, 'Africa/Accra', 'Africa/Accra', $5, $5, 'GHS'
      )
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(customer_id),
        payment_status,
        days_ahead,
        amount_minor
      ]
    )

    id
  end
end
