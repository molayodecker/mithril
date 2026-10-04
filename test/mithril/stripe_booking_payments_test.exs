defmodule Mithril.StripeBookingPaymentsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.StripeBookingPayments

  setup do
    :ok = Sandbox.checkout(Repo)
    previous_intents = Application.get_env(:mithril, :stripe_test_intents)
    create_payment_tables!()

    on_exit(fn ->
      if previous_intents do
        Application.put_env(:mithril, :stripe_test_intents, previous_intents)
      else
        Application.delete_env(:mithril, :stripe_test_intents)
      end
    end)

    :ok
  end

  test "does not settle another customer's payment intent supplied by the caller" do
    attacker_id = Ecto.UUID.generate()
    victim_id = Ecto.UUID.generate()
    attacker_booking = insert_booking!(attacker_id, "ref-attacker")
    victim_booking = insert_booking!(victim_id, "ref-victim")

    insert_attempt!(attacker_booking, "ref-attacker", "pi_attacker")
    insert_attempt!(victim_booking, "ref-victim", "pi_victim")
    put_succeeded_intent!("pi_victim", victim_booking, "ref-victim")

    assert {:ok, %{ok: true, data: data}} =
             StripeBookingPayments.verify_payment_intent(attacker_id, %{
               "booking_id" => attacker_booking,
               "payment_intent_id" => "pi_victim"
             })

    assert data.verified == false
    assert data.status == "missing"
    assert booking_payment_status!(victim_booking) == "pending"
    assert booking_payment_status!(attacker_booking) == "pending"
  end

  test "does not report Stripe success for an already-paid booking with a foreign intent" do
    customer_id = Ecto.UUID.generate()
    other_customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, "ref-paid")
    other_booking_id = insert_booking!(other_customer_id, "ref-other")

    insert_attempt!(booking_id, "ref-paid", "pi_paid")
    insert_attempt!(other_booking_id, "ref-other", "pi_other")
    Repo.query!("UPDATE public.bookings SET payment_status = 'paid', payment_method = 'paystack' WHERE id = $1", [
      Ecto.UUID.dump!(booking_id)
    ])

    assert {:ok, %{ok: true, data: data}} =
             StripeBookingPayments.verify_payment_intent(customer_id, %{
               "booking_id" => booking_id,
               "payment_intent_id" => "pi_other"
             })

    assert data.verified == false
    assert data.status == "missing"
    assert booking_payment_status!(booking_id) == "paid"
  end

  test "settles the caller's booking when the supplied payment intent belongs to it" do
    customer_id = Ecto.UUID.generate()
    booking_id = insert_booking!(customer_id, "ref-own")
    insert_attempt!(booking_id, "ref-own", "pi_own")
    put_succeeded_intent!("pi_own", booking_id, "ref-own")

    assert {:ok, %{ok: true, data: data}} =
             StripeBookingPayments.verify_payment_intent(customer_id, %{
               "booking_id" => booking_id,
               "payment_intent_id" => "pi_own"
             })

    assert data.verified == true
    assert data.status == "succeeded"
    assert data.paid_via_webhook == false
    assert booking_payment_status!(booking_id) == "paid"
  end

  defp put_succeeded_intent!(payment_intent_id, booking_id, reference) do
    intents = Application.get_env(:mithril, :stripe_test_intents, %{})

    record = %{
      "id" => payment_intent_id,
      "status" => "succeeded",
      "amount" => 1000,
      "amount_received" => 1000,
      "currency" => "usd",
      "metadata" => %{
        "booking_id" => booking_id,
        "reference" => reference,
        "booking_amount_minor" => 5_000,
        "booking_currency" => "ghs",
        "stripe_charge_amount_minor" => 1000,
        "stripe_charge_currency" => "usd"
      }
    }

    Application.put_env(
      :mithril,
      :stripe_test_intents,
      Map.put(intents, payment_intent_id, record)
    )
  end

  defp insert_booking!(customer_id, reference) do
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (id, customer_id, payment_status, reference)
      VALUES ($1, $2, 'pending', $3)
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), reference]
    )

    booking_id
  end

  defp insert_attempt!(booking_id, reference, payment_intent_id) do
    Repo.query!(
      """
      INSERT INTO public.payment_attempts (
        booking_id, provider, reference, status, amount_minor, currency, stripe_payment_intent_id
      )
      VALUES ($1, 'stripe', $2, 'ready', 5000, 'GHS', $3)
      """,
      [Ecto.UUID.dump!(booking_id), reference, payment_intent_id]
    )
  end

  defp booking_payment_status!(booking_id) do
    %{rows: [[status]]} =
      Repo.query!(
        "SELECT payment_status FROM public.bookings WHERE id = $1",
        [Ecto.UUID.dump!(booking_id)]
      )

    status
  end

  defp create_payment_tables! do
    Repo.query!("DROP TABLE IF EXISTS public.payment_attempts CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.bookings CASCADE")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      payment_status text NOT NULL DEFAULT 'pending',
      payment_method text,
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
      status text NOT NULL,
      amount_minor bigint NOT NULL,
      currency text NOT NULL,
      stripe_payment_intent_id text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      paid_at timestamptz
    )
    """)
  end
end
