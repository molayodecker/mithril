defmodule Mithril.DirectBookingsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectBookingCancels
  alias Mithril.DirectBookings
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_booking_tables!()
    Application.delete_env(:mithril, :paystack_test_refund_result)

    on_exit(fn ->
      Application.delete_env(:mithril, :paystack_test_refund_result)
    end)

    :ok
  end

  test "client self-serve booking is disabled unless the flag is on" do
    customer_id = Ecto.UUID.generate()

    assert {:error, :client_bookings_disabled} =
             DirectBookings.create_customer_booking(customer_id, %{})

    previous = Application.get_env(:mithril, :direct_client_bookings, false)
    Application.put_env(:mithril, :direct_client_bookings, true)

    on_exit(fn ->
      Application.put_env(:mithril, :direct_client_bookings, previous)
    end)

    assert {:error, :invalid_user} = DirectBookings.create_customer_booking("not-a-uuid", %{})
  end

  test "lists only the signed-in customer's bookings, newest first" do
    customer_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    older = insert_booking!(customer_id, ~D[2026-09-10], ~T[09:00:00], "scheduled")
    newer = insert_booking!(customer_id, ~D[2026-09-20], ~T[14:00:00], "pending")
    _other = insert_booking!(other_id, ~D[2026-09-22], ~T[08:00:00], "scheduled")

    assert {:ok, bookings} = DirectBookings.list_bookings(customer_id)
    assert Enum.map(bookings, & &1["id"]) == [newer, older]
    assert hd(bookings)["serviceName"] == "Regular Cleaning"
    assert hd(bookings)["amountMinor"] == 19_350
    assert hd(bookings)["currency"] == "GHS"
  end

  test "returns an empty list when the customer has no bookings" do
    assert {:ok, []} = DirectBookings.list_bookings(Ecto.UUID.generate())
  end

  test "cancels an unpaid booking without calling Paystack" do
    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "pending")

    assert {:ok, result} = DirectBookingCancels.cancel(customer_id, booking_id, %{})
    assert result.status == "cancelled"
    assert result.paymentStatus == "pending"
    assert result.refundStatus == "skipped"
    assert result.refundPercent == 0
    assert result.successMessage == "Your booking has been cancelled."

    assert [["cancelled", "pending"]] =
             Repo.query!(
               "SELECT status, payment_status FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "records staff as the actor when ops cancel a customer booking" do
    customer_id = Ecto.UUID.generate()
    admin_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "pending")

    assert {:ok, result} =
             DirectBookingCancels.cancel(customer_id, booking_id, %{}, {:admin, admin_id})

    assert result.status == "cancelled"

    assert [["admin", "admin_cancelled", dumped_admin]] =
             Repo.query!(
               """
               SELECT cancelled_by_role, cancellation_reason_code, cancelled_by
               FROM public.bookings WHERE id = $1
               """,
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert dumped_admin == Ecto.UUID.dump!(admin_id)

    assert [["admin", "admin_cancelled"]] =
             Repo.query!(
               """
               SELECT refund_attribution_role, refund_reason_code
               FROM public.booking_refunds WHERE booking_id = $1
               """,
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "queues a full Paystack refund for a paid booking more than 24 hours away" do
    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid",
        reference: "T_direct_full"
      )

    assert {:ok, result} = DirectBookingCancels.cancel(customer_id, booking_id, %{})
    assert result.status == "cancelled"
    assert result.paymentStatus == "paid"
    assert result.tier == "full_refund"
    assert result.refundPercent == 100
    assert result.refundAmountMinor == 19_350
    assert result.refundStatus == "pending"
    assert result.successMessage =~ "full refund"

    assert [["pending", "T_direct_full", "rf_T_direct_full"]] =
             Repo.query!(
               """
               SELECT status, paystack_transaction_reference, paystack_refund_reference
               FROM public.booking_refunds WHERE booking_id = $1
               """,
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "rejects automatic cancellation while a direct refund request is actionable" do
    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid",
        reference: "T_direct_queued_request"
      )

    Repo.query!(
      """
      INSERT INTO public.direct_refund_requests (booking_id, status)
      VALUES ($1, 'requested')
      """,
      [Ecto.UUID.dump!(booking_id)]
    )

    assert {:error, {:refund_request_conflict, message}} =
             DirectBookingCancels.cancel(customer_id, booking_id, %{})

    assert message =~ "refund request in progress"

    assert [["scheduled"]] =
             Repo.query!(
               "SELECT status FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM public.booking_refunds WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "is idempotent once a refund row exists" do
    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid",
        reference: "T_direct_once"
      )

    assert {:ok, first} = DirectBookingCancels.cancel(customer_id, booking_id, %{})
    assert {:ok, second} = DirectBookingCancels.cancel(customer_id, booking_id, %{})
    assert second.refundStatus == first.refundStatus
    assert second.refundAmountMinor == first.refundAmountMinor

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM public.booking_refunds WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "rejects completed bookings" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, Date.utc_today(), ~T[10:00:00], "completed")

    assert {:error, {:not_cancellable, message}} =
             DirectBookingCancels.cancel(customer_id, booking_id, %{})

    assert message == "Completed bookings cannot be cancelled."
  end

  test "does not cancel another customer's booking" do
    owner_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(owner_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled")

    assert {:error, :not_found} = DirectBookingCancels.cancel(other_id, booking_id, %{})
  end

  test "holds an ambiguous Paystack refund for manual review without rolling back the cancel" do
    Application.put_env(:mithril, :paystack_test_refund_result, {:error, :provider_unavailable})

    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid",
        reference: "T_direct_unknown_refund"
      )

    assert {:ok, result} = DirectBookingCancels.cancel(customer_id, booking_id, %{})
    assert result.status == "cancelled"
    assert result.refundStatus == "manual_review"
    assert result.successMessage =~ "process your refund manually"

    assert [["manual_review", reason]] =
             Repo.query!(
               "SELECT status, failure_reason FROM public.booking_refunds WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert reason =~ "verify provider state before retrying"
  end

  test "holds Paystack 5xx refund responses for manual review" do
    Application.put_env(
      :mithril,
      :paystack_test_refund_result,
      {:error, {:provider, 503, "provider unavailable"}}
    )

    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid",
        reference: "T_direct_5xx_refund"
      )

    assert {:ok, result} = DirectBookingCancels.cancel(customer_id, booking_id, %{})
    assert result.status == "cancelled"
    assert result.refundStatus == "manual_review"
    assert result.successMessage =~ "process your refund manually"

    assert [["manual_review", reason]] =
             Repo.query!(
               "SELECT status, failure_reason FROM public.booking_refunds WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert reason =~ "verify provider state before retrying"
    assert reason =~ "provider unavailable"
  end

  test "records a definite Paystack refund rejection as failed" do
    Application.put_env(
      :mithril,
      :paystack_test_refund_result,
      {:error, {:provider, 400, "refund rejected"}}
    )

    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid",
        reference: "T_direct_rejected_refund"
      )

    assert {:ok, result} = DirectBookingCancels.cancel(customer_id, booking_id, %{})
    assert result.status == "cancelled"
    assert result.refundStatus == "failed"
    assert result.successMessage =~ "could not process your refund automatically"

    assert [["failed"]] =
             Repo.query!(
               "SELECT status FROM public.booking_refunds WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "reschedules a paid booking without changing its paid duration or amount" do
    customer_id = Ecto.UUID.generate()
    new_date = Date.add(Date.utc_today(), 5)

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid"
      )

    assert {:ok, booking} =
             DirectBookings.reschedule(customer_id, booking_id, %{
               "scheduledDate" => Date.to_iso8601(new_date),
               "scheduledTime" => "14:00",
               "durationHours" => 8
             })

    assert booking["id"] == booking_id
    assert booking["status"] == "scheduled"
    assert booking["paymentStatus"] == "paid"
    assert booking["scheduledDate"] == Date.to_iso8601(new_date)
    assert booking["amountMinor"] == 19_350

    assert [[duration_hours, duration_final]] =
             Repo.query!(
               "SELECT duration_hours, duration_final FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert Decimal.equal?(duration_hours, Decimal.new(3))
    assert Decimal.equal?(duration_final, Decimal.new(3))
  end

  test "clears every reminder stamp when the visit moves" do
    customer_id = Ecto.UUID.generate()
    new_date = Date.add(Date.utc_today(), 5)

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid"
      )

    Repo.query!(
      """
      UPDATE public.bookings SET
        customer_reminder_sent_at = now(),
        customer_reminder_claimed_at = now(),
        customer_reminder_7d_sent_at = now(),
        customer_reminder_7d_claimed_at = now(),
        customer_reminder_48h_sent_at = now(),
        customer_reminder_48h_claimed_at = now(),
        customer_reminder_morning_sent_at = now(),
        customer_reminder_morning_claimed_at = now(),
        cleaner_reminder_sent_at = now(),
        cleaner_reminder_claimed_at = now()
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(booking_id)]
    )

    assert {:ok, _} =
             DirectBookings.reschedule(customer_id, booking_id, %{
               "scheduledDate" => Date.to_iso8601(new_date),
               "scheduledTime" => "14:00"
             })

    [[stamps]] =
      Repo.query!(
        """
        SELECT ARRAY[
          customer_reminder_sent_at,
          customer_reminder_claimed_at,
          customer_reminder_7d_sent_at,
          customer_reminder_7d_claimed_at,
          customer_reminder_48h_sent_at,
          customer_reminder_48h_claimed_at,
          customer_reminder_morning_sent_at,
          customer_reminder_morning_claimed_at,
          cleaner_reminder_sent_at,
          cleaner_reminder_claimed_at
        ]
        FROM public.bookings WHERE id = $1
        """,
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert Enum.all?(stamps, &is_nil/1)
  end

  test "reprices an unpaid pending booking when the schedule changes" do
    customer_id = Ecto.UUID.generate()
    new_date = Date.add(Date.utc_today(), 6)

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[09:00:00], "pending")

    assert {:ok, booking} =
             DirectBookings.reschedule(customer_id, booking_id, %{
               "scheduledDate" => Date.to_iso8601(new_date),
               "scheduledTime" => "11:30"
             })

    assert booking["paymentStatus"] == "pending"
    assert booking["scheduledDate"] == Date.to_iso8601(new_date)
    assert booking["amountMinor"] == 19_350
  end

  test "invalidates an active checkout when unpaid rescheduling changes the price" do
    customer_id = Ecto.UUID.generate()
    new_date = Date.add(Date.utc_today(), 6)
    reference = "BK-stale-reschedule"

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[09:00:00], "pending")

    Repo.query!(
      """
      UPDATE public.bookings
      SET final_amount_minor = 10000,
          total_price = 10000,
          reference = $2
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(booking_id), reference]
    )

    Repo.query!(
      """
      INSERT INTO public.payment_attempts (
        booking_id, reference, status, amount_minor, currency
      ) VALUES ($1, $2, 'ready', 10000, 'GHS')
      """,
      [Ecto.UUID.dump!(booking_id), reference]
    )

    assert {:ok, booking} =
             DirectBookings.reschedule(customer_id, booking_id, %{
               "scheduledDate" => Date.to_iso8601(new_date),
               "scheduledTime" => "11:30"
             })

    assert booking["amountMinor"] == 19_350

    assert [[nil]] =
             Repo.query!(
               "SELECT reference FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert [["failed", "Booking repriced during reschedule"]] =
             Repo.query!(
               "SELECT status, failure_reason FROM public.payment_attempts WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "rejects rescheduling to a past time" do
    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid"
      )

    assert {:error, {:past_schedule, message}} =
             DirectBookings.reschedule(customer_id, booking_id, %{
               "scheduledDate" => Date.to_iso8601(Date.utc_today()),
               "scheduledTime" => "00:00"
             })

    assert message =~ "past time"
  end

  test "rejects rescheduling a completed booking" do
    customer_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "completed")

    assert {:error, {:not_reschedulable, message}} =
             DirectBookings.reschedule(customer_id, booking_id, %{
               "scheduledDate" => Date.to_iso8601(Date.add(Date.utc_today(), 5)),
               "scheduledTime" => "10:00"
             })

    assert message =~ "current status"
  end

  test "rejects rescheduling a subscription visit" do
    customer_id = Ecto.UUID.generate()
    subscription_id = Ecto.UUID.generate()

    booking_id =
      insert_booking!(customer_id, Date.add(Date.utc_today(), 3), ~T[10:00:00], "scheduled",
        payment_status: "paid",
        subscription_id: subscription_id
      )

    assert {:error, {:not_reschedulable, message}} =
             DirectBookings.reschedule(customer_id, booking_id, %{
               "scheduledDate" => Date.to_iso8601(Date.add(Date.utc_today(), 5)),
               "scheduledTime" => "10:00"
             })

    assert message =~ "subscription"
  end

  defp insert_booking!(customer_id, scheduled_date, scheduled_time, status, opts \\ []) do
    booking_id = Ecto.UUID.generate()
    payment_status = Keyword.get(opts, :payment_status, "pending")
    reference = Keyword.get(opts, :reference)
    subscription_id = Keyword.get(opts, :subscription_id)

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
        id, customer_id, service_id, status, payment_status, reference,
        scheduled_date, scheduled_time, duration_hours, duration_final, address,
        final_amount_minor, total_price, currency, timezone, timezone_name,
        subscription_id
      ) VALUES (
        $1, $2, 1, $3, $4, $5, $6, $7, 3, 3, 'Labone, Accra',
        19350, 19350, 'GHS', 'Africa/Accra', 'Africa/Accra', $8
      )
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(customer_id),
        status,
        payment_status,
        reference,
        scheduled_date,
        scheduled_time,
        subscription_id && Ecto.UUID.dump!(subscription_id)
      ]
    )

    booking_id
  end

  defp create_booking_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate booking fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.direct_refund_requests CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.booking_refunds CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.payment_attempts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.cleaner_availability_exceptions CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.service_types CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.profiles CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.validate_booking_timeslot_24h(text, numeric, date, text)"
    )

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.cleaner_has_booking_conflict(uuid, timestamptz, timestamptz, uuid)"
    )

    Repo.query!("DROP FUNCTION IF EXISTS public.compute_booking_pricing")

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text,
      status text NOT NULL DEFAULT 'active'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      lastname text,
      avatar_url text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_types (
      id integer PRIMARY KEY,
      name text NOT NULL,
      price numeric,
      active boolean NOT NULL DEFAULT true,
      specialty_slug text
    )
    """)

    Repo.query!(
      "INSERT INTO public.service_types (id, name, specialty_slug) VALUES (1, 'Regular Cleaning', 'regular_cleaning')"
    )

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      service_id integer NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      payment_status text NOT NULL DEFAULT 'pending',
      reference text,
      scheduled_date date,
      scheduled_time time,
      duration_hours numeric,
      duration_final numeric,
      address text,
      final_amount_minor bigint,
      total_price numeric,
      currency text NOT NULL DEFAULT 'GHS',
      timezone text,
      timezone_name text,
      subscription_id uuid,
      customer_reminder_sent_at timestamptz,
      customer_reminder_claimed_at timestamptz,
      customer_reminder_7d_sent_at timestamptz,
      customer_reminder_7d_claimed_at timestamptz,
      customer_reminder_48h_sent_at timestamptz,
      customer_reminder_48h_claimed_at timestamptz,
      customer_reminder_morning_sent_at timestamptz,
      customer_reminder_morning_claimed_at timestamptz,
      cleaner_reminder_sent_at timestamptz,
      cleaner_reminder_claimed_at timestamptz,
      core_amount_minor integer,
      same_day_surcharge_minor integer,
      weekend_surcharge_minor integer,
      recurring_discount_minor integer,
      is_same_day boolean,
      is_weekend boolean,
      pricing_version text,
      platform_fee numeric,
      booking_cover numeric,
      booking_cover_amount numeric,
      work_rate_ghs_per_hour numeric,
      supplies_option text,
      supplies_allowance_minor integer,
      cleaner_earnings_minor integer,
      created_at timestamptz NOT NULL DEFAULT now(),
      cancelled_at timestamptz,
      cancelled_by uuid,
      cancelled_by_role text,
      cancellation_tier text,
      cancellation_reason text,
      cancellation_reason_code text,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payment_attempts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
      reference text NOT NULL UNIQUE,
      status text NOT NULL DEFAULT 'initializing',
      amount_minor bigint NOT NULL,
      currency text NOT NULL DEFAULT 'GHS',
      failure_reason text,
      failed_at timestamptz,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_availability_exceptions (
      cleaner_id uuid NOT NULL,
      exception_date date NOT NULL
    )
    """)

    Repo.query!("""
    CREATE FUNCTION public.validate_booking_timeslot_24h(
      text, numeric, date, text
    ) RETURNS boolean
    LANGUAGE sql AS $$ SELECT true $$
    """)

    Repo.query!("""
    CREATE FUNCTION public.cleaner_has_booking_conflict(
      uuid, timestamptz, timestamptz, uuid
    ) RETURNS boolean
    LANGUAGE sql AS $$ SELECT false $$
    """)

    Repo.query!("""
    CREATE FUNCTION public.compute_booking_pricing(
      p_service_id integer,
      p_duration_hours_raw numeric,
      p_scheduled_date date,
      p_service_timezone text,
      p_recurrence_interval text DEFAULT NULL,
      p_is_recurring boolean DEFAULT false,
      p_include_booking_cover boolean DEFAULT true,
      p_supplies_option text DEFAULT NULL,
      p_cleaner_id uuid DEFAULT NULL,
      p_extra_task_ids integer[] DEFAULT NULL,
      p_service_duration_option_id integer DEFAULT NULL,
      p_visit_duration_hours numeric DEFAULT NULL,
      p_cleaning_scan_id uuid DEFAULT NULL
    ) RETURNS TABLE (
      currency text,
      pricing_version text,
      duration_hours numeric,
      work_rate_ghs_per_hour numeric,
      subtotal_labor_major numeric,
      platform_fee_major numeric,
      booking_cover_major numeric,
      core_amount_minor integer,
      same_day_surcharge_minor integer,
      weekend_surcharge_minor integer,
      recurring_discount_minor integer,
      final_amount_minor integer,
      is_same_day boolean,
      is_weekend boolean,
      supplies_option text,
      supplies_allowance_minor integer,
      cleaner_earnings_minor integer
    )
    LANGUAGE sql AS $$
      SELECT
        'GHS',
        'test',
        p_duration_hours_raw,
        50::numeric,
        100::numeric,
        10::numeric,
        5::numeric,
        19350,
        0,
        0,
        0,
        19350,
        false,
        false,
        'customer_provided',
        0,
        15000
    $$
    """)

    Repo.query!("""
    CREATE TABLE public.booking_refunds (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL UNIQUE REFERENCES public.bookings(id) ON DELETE CASCADE,
      customer_id uuid NOT NULL,
      tier text NOT NULL,
      refund_percent integer NOT NULL,
      refund_amount_minor integer NOT NULL DEFAULT 0,
      paystack_transaction_reference text,
      paystack_refund_reference text,
      status text NOT NULL DEFAULT 'pending',
      failure_reason text,
      refund_attribution_role text,
      refund_reason_code text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.direct_refund_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
      status text NOT NULL DEFAULT 'requested',
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)
  end
end
