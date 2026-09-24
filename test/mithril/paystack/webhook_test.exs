defmodule Mithril.Paystack.WebhookTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Paystack.Webhook
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    recreate_tables()
    :ok
  end

  test "rejects a missing or invalid signature" do
    raw = ~s({"event":"charge.success","data":{"reference":"r1"}})

    assert {:error, :unauthorized} = Webhook.handle(raw, nil)
    assert {:error, :unauthorized} = Webhook.handle(raw, String.duplicate("a", 128))
  end

  test "ignores events Mithril does not settle" do
    raw = Jason.encode!(%{"event" => "subscription.create", "data" => %{}})

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.ignored
    assert result.reason == "unhandled_event"
  end

  test "ignores charge.success for an unknown reference" do
    raw =
      Jason.encode!(%{
        "event" => "charge.success",
        "data" => %{
          "reference" => "unknown-ref",
          "status" => "success",
          "amount" => 100,
          "currency" => "GHS"
        }
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.ignored
    assert result.reason == "unknown_reference"
  end

  test "settles charge.success against payment_attempts.reference" do
    {booking_id, reference} = insert_pending_booking!(20_000)

    raw = charge_success(reference, 20_000)
    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.settled
    assert result.reference == reference

    [[payment_status, payment_method]] =
      Repo.query!(
        "SELECT payment_status, payment_method FROM public.bookings WHERE id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert payment_status == "paid"
    assert payment_method == "paystack"

    [[status]] =
      Repo.query!(
        "SELECT status FROM public.payment_attempts WHERE reference = $1",
        [reference]
      ).rows

    assert status == "paid"

    assert {:ok, replay} = Webhook.handle(raw, sign(raw))
    assert replay.already_paid
  end

  test "rejects charge.success when the amount does not match" do
    {_booking_id, reference} = insert_pending_booking!(20_000)
    raw = charge_success(reference, 1)

    assert {:error, :amount_mismatch} = Webhook.handle(raw, sign(raw))
  end

  test "does not settle a successful charge after the booking was cancelled" do
    {booking_id, reference} = insert_pending_booking!(20_000)

    Repo.query!(
      "UPDATE public.bookings SET status = 'cancelled' WHERE id = $1",
      [Ecto.UUID.dump!(booking_id)]
    )

    raw = charge_success(reference, 20_000)

    assert {:error, :payment_not_payable} = Webhook.handle(raw, sign(raw))

    assert [["cancelled", "pending"]] =
             Repo.query!(
               "SELECT status, payment_status FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert [["ready"]] =
             Repo.query!(
               "SELECT status FROM public.payment_attempts WHERE reference = $1",
               [Ecto.UUID.dump!(reference)]
             ).rows
  end

  test "rejects charge.success when amount or currency is missing" do
    {_booking_id, reference} = insert_pending_booking!(20_000)

    missing_amount =
      Jason.encode!(%{
        "event" => "charge.success",
        "data" => %{"reference" => reference, "status" => "success", "currency" => "GHS"}
      })

    assert {:error, :amount_mismatch} = Webhook.handle(missing_amount, sign(missing_amount))

    missing_currency =
      Jason.encode!(%{
        "event" => "charge.success",
        "data" => %{"reference" => reference, "status" => "success", "amount" => 20_000}
      })

    assert {:error, :amount_mismatch} =
             Webhook.handle(missing_currency, sign(missing_currency))
  end

  test "returns database_unavailable when charge settlement tables are missing" do
    {_booking_id, reference} = insert_pending_booking!(20_000)
    Repo.query!("DROP TABLE public.payment_attempts")

    raw = charge_success(reference, 20_000)

    assert {:error, :database_unavailable} = Webhook.handle(raw, sign(raw))
  end

  test "marks charge.failed on an initializing attempt" do
    {_booking_id, reference} = insert_pending_booking!(10_000)

    raw =
      Jason.encode!(%{
        "event" => "charge.failed",
        "data" => %{
          "reference" => reference,
          "gateway_response" => "Insufficient funds"
        }
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.failed

    [[status, reason]] =
      Repo.query!(
        "SELECT status, failure_reason FROM public.payment_attempts WHERE reference = $1",
        [reference]
      ).rows

    assert status == "failed"
    assert reason == "Insufficient funds"
  end

  test "settles transfer.success and treats replay as idempotent" do
    {reference, _user_id} = insert_payout!("pending", 12_500)

    raw = transfer_event("transfer.success", reference, 12_500, "GHS", "TRF_123")
    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.settled
    assert result.transfer_status == "success"

    assert [["success", "TRF_123", nil]] =
             Repo.query!(
               """
               SELECT status::text, paystack_transfer_code, error_message
               FROM public.cleaner_payouts
               WHERE reference = $1::uuid
               """,
               [Ecto.UUID.dump!(reference)]
             ).rows

    assert {:ok, replay} = Webhook.handle(raw, sign(raw))
    assert replay.already_settled
    assert replay.transfer_status == "success"
  end

  test "rejects transfer.success when amount or currency does not match" do
    {reference, _user_id} = insert_payout!("pending", 12_500)

    wrong_amount = transfer_event("transfer.success", reference, 1, "GHS", "TRF_amount")
    assert {:error, :amount_mismatch} = Webhook.handle(wrong_amount, sign(wrong_amount))

    wrong_currency = transfer_event("transfer.success", reference, 12_500, "USD", "TRF_currency")
    assert {:error, :amount_mismatch} = Webhook.handle(wrong_currency, sign(wrong_currency))

    assert [["pending"]] =
             Repo.query!(
               "SELECT status::text FROM public.cleaner_payouts WHERE reference = $1::uuid",
               [Ecto.UUID.dump!(reference)]
             ).rows
  end

  test "finalizes transfer.failed and preserves the provider reason" do
    {reference, _user_id} = insert_payout!("processing", 12_500)

    raw =
      Jason.encode!(%{
        "event" => "transfer.failed",
        "data" => %{
          "reference" => reference,
          "transfer_code" => "TRF_failed",
          "reason" => "Recipient unavailable"
        }
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.settled
    assert result.transfer_status == "failed"

    assert [["failed", "TRF_failed", "Recipient unavailable"]] =
             Repo.query!(
               """
               SELECT status::text, paystack_transfer_code, error_message
               FROM public.cleaner_payouts
               WHERE reference = $1::uuid
               """,
               [Ecto.UUID.dump!(reference)]
             ).rows
  end

  test "allows a later transfer.reversed to reverse a successful withdrawal" do
    {reference, _user_id} = insert_payout!("success", 12_500)

    raw =
      Jason.encode!(%{
        "event" => "transfer.reversed",
        "data" => %{
          "reference" => reference,
          "transfer_code" => "TRF_reversed",
          "reason" => "Bank reversal"
        }
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.settled
    assert result.transfer_status == "reversed"

    assert [["reversed", "Bank reversal"]] =
             Repo.query!(
               """
               SELECT status::text, error_message
               FROM public.cleaner_payouts
               WHERE reference = $1::uuid
               """,
               [Ecto.UUID.dump!(reference)]
             ).rows
  end

  test "does not let a stale transfer.failed overwrite success" do
    {reference, _user_id} = insert_payout!("success", 12_500)

    raw =
      Jason.encode!(%{
        "event" => "transfer.failed",
        "data" => %{"reference" => reference, "reason" => "stale failure"}
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.ignored
    assert result.reason == "terminal_transfer_status"

    assert [["success"]] =
             Repo.query!(
               "SELECT status::text FROM public.cleaner_payouts WHERE reference = $1::uuid",
               [Ecto.UUID.dump!(reference)]
             ).rows
  end

  test "settles refund.processed to refunded for a 100% refund" do
    {booking_id, reference} = insert_paid_booking!(20_000)
    insert_refund!(booking_id, reference, 100, 20_000)

    raw =
      Jason.encode!(%{
        "event" => "refund.processed",
        "data" => %{
          "transaction_reference" => reference,
          "refund_reference" => "rfd_1",
          "status" => "processed",
          "amount" => 20_000,
          "currency" => "GHS"
        }
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.refund_status == "processed"
    assert result.payment_status == "refunded"

    [[payment_status]] =
      Repo.query!(
        "SELECT payment_status FROM public.bookings WHERE id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert payment_status == "refunded"

    [[status, refund_ref]] =
      Repo.query!(
        "SELECT status, paystack_refund_reference FROM public.booking_refunds WHERE booking_id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert status == "processed"
    assert refund_ref == "rfd_1"
  end

  test "rejects refund.processed when amount or currency does not match" do
    {booking_id, reference} = insert_paid_booking!(20_000)
    insert_refund!(booking_id, reference, 100, 20_000)

    wrong_amount =
      Jason.encode!(%{
        "event" => "refund.processed",
        "data" => %{
          "transaction_reference" => reference,
          "refund_reference" => "rfd_amount",
          "status" => "processed",
          "amount" => 1,
          "currency" => "GHS"
        }
      })

    assert {:error, :amount_mismatch} = Webhook.handle(wrong_amount, sign(wrong_amount))

    wrong_currency =
      Jason.encode!(%{
        "event" => "refund.processed",
        "data" => %{
          "transaction_reference" => reference,
          "refund_reference" => "rfd_currency",
          "status" => "processed",
          "amount" => 20_000,
          "currency" => "USD"
        }
      })

    assert {:error, :amount_mismatch} =
             Webhook.handle(wrong_currency, sign(wrong_currency))

    assert [["pending"]] =
             Repo.query!(
               "SELECT status FROM public.booking_refunds WHERE booking_id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows

    assert [["paid"]] =
             Repo.query!(
               "SELECT payment_status FROM public.bookings WHERE id = $1",
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "does not fall back to transaction reference when refund reference conflicts" do
    {booking_id, reference} = insert_paid_booking!(20_000)
    insert_refund!(booking_id, reference, 100, 20_000)

    Repo.query!(
      """
      UPDATE public.booking_refunds
      SET paystack_refund_reference = 'rfd_expected'
      WHERE booking_id = $1
      """,
      [Ecto.UUID.dump!(booking_id)]
    )

    raw =
      Jason.encode!(%{
        "event" => "refund.processed",
        "data" => %{
          "transaction_reference" => reference,
          "refund_reference" => "rfd_other",
          "status" => "processed",
          "amount" => 20_000,
          "currency" => "GHS"
        }
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.ignored
    assert result.reason == "unknown_refund"

    assert [["pending", "rfd_expected"]] =
             Repo.query!(
               """
               SELECT status, paystack_refund_reference
               FROM public.booking_refunds
               WHERE booking_id = $1
               """,
               [Ecto.UUID.dump!(booking_id)]
             ).rows
  end

  test "does not reopen a processed refund on a later pending event" do
    {booking_id, reference} = insert_paid_booking!(20_000)
    insert_refund!(booking_id, reference, 100, 20_000, "processed")

    Repo.query!(
      "UPDATE public.bookings SET payment_status = 'refunded' WHERE id = $1",
      [Ecto.UUID.dump!(booking_id)]
    )

    raw =
      Jason.encode!(%{
        "event" => "refund.pending",
        "data" => %{"transaction_reference" => reference}
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.ignored
    assert result.reason == "already_processed"

    [[status]] =
      Repo.query!(
        "SELECT status FROM public.booking_refunds WHERE booking_id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    assert status == "processed"
  end

  defp transfer_event(event, reference, amount, currency, transfer_code) do
    Jason.encode!(%{
      "event" => event,
      "data" => %{
        "reference" => reference,
        "status" => "success",
        "amount" => amount,
        "currency" => currency,
        "transfer_code" => transfer_code
      }
    })
  end

  defp insert_payout!(status, amount) do
    user_id = Ecto.UUID.generate()
    reference = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO public.users (id) VALUES ($1) ON CONFLICT DO NOTHING",
      [Ecto.UUID.dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.cleaner_payouts (
        id, user_id, recipient_code, amount, currency, reference, status
      ) VALUES ($1, $2, 'RCP_test', $3, 'GHS', $4::uuid, $5::public.withdrawal_status)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(user_id),
        amount,
        Ecto.UUID.dump!(reference),
        status
      ]
    )

    {reference, user_id}
  end

  defp charge_success(reference, amount) do
    Jason.encode!(%{
      "event" => "charge.success",
      "data" => %{
        "reference" => reference,
        "status" => "success",
        "amount" => amount,
        "currency" => "GHS"
      }
    })
  end

  defp sign(raw) do
    secret = Application.fetch_env!(:mithril, :paystack_secret_key)

    :hmac
    |> :crypto.mac(:sha512, secret, raw)
    |> Base.encode16(case: :lower)
  end

  defp insert_pending_booking!(amount) do
    insert_booking!("pending", amount)
  end

  defp insert_paid_booking!(amount) do
    insert_booking!("paid", amount)
  end

  defp insert_booking!(payment_status, amount) do
    user_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()
    attempt_id = Ecto.UUID.generate()
    reference = "BK-#{booking_id}-webhook"

    Repo.query!(
      "INSERT INTO public.users (id) VALUES ($1)",
      [Ecto.UUID.dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, status, payment_status, payment_method, reference, final_amount_minor, currency
      ) VALUES ($1, $2, 'pending', $3, $4, $5, $6, 'GHS')
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(user_id),
        payment_status,
        if(payment_status == "paid", do: "paystack", else: nil),
        reference,
        amount
      ]
    )

    Repo.query!(
      """
      INSERT INTO public.payment_attempts (
        id, booking_id, reference, request_fingerprint, status, amount_minor, currency, expires_at
      ) VALUES ($1, $2, $3, $4, $5, $6, 'GHS', now() + interval '15 minutes')
      """,
      [
        Ecto.UUID.dump!(attempt_id),
        Ecto.UUID.dump!(booking_id),
        reference,
        "fp-#{reference}",
        if(payment_status == "paid", do: "paid", else: "ready"),
        amount
      ]
    )

    {booking_id, reference}
  end

  defp insert_refund!(booking_id, reference, percent, amount, status \\ "pending") do
    [[customer_id]] =
      Repo.query!(
        "SELECT customer_id FROM public.bookings WHERE id = $1",
        [Ecto.UUID.dump!(booking_id)]
      ).rows

    Repo.query!(
      """
      INSERT INTO public.booking_refunds (
        booking_id, customer_id, tier, refund_percent, refund_amount_minor,
        paystack_transaction_reference, status
      ) VALUES ($1, $2, 'full', $3, $4, $5, $6)
      """,
      [Ecto.UUID.dump!(booking_id), customer_id, percent, amount, reference, status]
    )
  end

  defp recreate_tables do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate Paystack fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["cleaner_payouts", "booking_refunds", "payment_attempts", "bookings", "users"] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    DO $withdrawal$
    BEGIN
      CREATE TYPE public.withdrawal_status AS ENUM (
        'pending', 'processing', 'success', 'failed', 'reversed'
      );
    EXCEPTION
      WHEN duplicate_object THEN NULL;
    END
    $withdrawal$;
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_payouts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      recipient_code text NOT NULL,
      amount integer NOT NULL,
      currency text NOT NULL DEFAULT 'GHS',
      reference uuid NOT NULL UNIQUE,
      status public.withdrawal_status NOT NULL DEFAULT 'pending',
      paystack_transfer_code text,
      paystack_transfer_id bigint,
      error_message text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.fn_finalize_withdrawal(
      p_transfer_reference text,
      p_status public.withdrawal_status,
      p_error_msg text,
      p_paystack_transfer_code text
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $finalize$
    BEGIN
      UPDATE public.cleaner_payouts
      SET status = p_status,
          error_message = p_error_msg,
          paystack_transfer_code = COALESCE(p_paystack_transfer_code, paystack_transfer_code),
          updated_at = now()
      WHERE reference = p_transfer_reference::uuid;
    END;
    $finalize$;
    """)

    Repo.query!("CREATE TABLE public.users (id uuid PRIMARY KEY)")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      payment_status text NOT NULL DEFAULT 'pending',
      payment_method text,
      reference text,
      final_amount_minor bigint NOT NULL,
      currency text NOT NULL DEFAULT 'GHS',
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payment_attempts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
      reference text NOT NULL UNIQUE,
      request_fingerprint text NOT NULL,
      status text NOT NULL DEFAULT 'initializing',
      amount_minor bigint NOT NULL,
      currency text NOT NULL,
      failure_reason text,
      expires_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      paid_at timestamptz,
      failed_at timestamptz
    )
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
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)
  end
end
