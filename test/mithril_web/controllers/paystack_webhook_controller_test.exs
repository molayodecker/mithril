defmodule MithrilWeb.PaystackWebhookControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  @endpoint MithrilWeb.Endpoint

  setup do
    :ok = Sandbox.checkout(Repo)
    recreate_tables()
    :ok
  end

  test "POST /webhooks/paystack accepts a signed charge.success payload" do
    {_booking_id, reference} = insert_pending_booking!(15_000)
    raw = charge_success(reference, 15_000)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(raw))
      |> post("/webhooks/paystack", raw)

    assert %{
             "ok" => true,
             "event" => "charge.success",
             "settled" => true,
             "ignored" => false,
             "reference" => ^reference
           } = json_response(conn, 200)
  end

  test "POST /webhooks/paystack returns 200 for an unknown dashboard test charge" do
    raw = charge_success("paystack-dashboard-test", 100)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(raw))
      |> post("/webhooks/paystack", raw)

    assert %{
             "ok" => true,
             "event" => "charge.success",
             "ignored" => true
           } = json_response(conn, 200)
  end

  test "POST /webhooks/paystack returns 422 when the charged amount does not match" do
    {_booking_id, reference} = insert_pending_booking!(15_000)
    raw = charge_success(reference, 1)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(raw))
      |> post("/webhooks/paystack", raw)

    assert %{"error" => "Amount mismatch"} = json_response(conn, 422)
  end

  test "POST /webhooks/paystack rejects a missing signature" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/paystack", ~s({"event":"charge.success"}))

    assert %{"error" => "Invalid webhook signature"} = json_response(conn, 401)
  end

  test "POST /webhooks/paystack rejects a bad signature" do
    raw = ~s({"event":"charge.success","data":{"reference":"r1"}})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", String.duplicate("a", 128))
      |> post("/webhooks/paystack", raw)

    assert %{"error" => "Invalid webhook signature"} = json_response(conn, 401)
  end

  test "POST /webhooks/paystack returns 503 when the secret is missing" do
    previous = Application.get_env(:mithril, :paystack_secret_key)
    Application.delete_env(:mithril, :paystack_secret_key)

    on_exit(fn -> Application.put_env(:mithril, :paystack_secret_key, previous) end)

    raw = ~s({"event":"charge.success"})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", String.duplicate("a", 128))
      |> post("/webhooks/paystack", raw)

    assert %{"error" => "Missing PAYSTACK_SECRET_KEY"} = json_response(conn, 503)
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
    user_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()
    reference = "BK-#{booking_id}-http"

    Repo.query!("INSERT INTO public.users (id) VALUES ($1)", [Ecto.UUID.dump!(user_id)])

    Repo.query!(
      """
      INSERT INTO public.bookings (
        id, customer_id, status, payment_status, reference, final_amount_minor, currency
      ) VALUES ($1, $2, 'pending', 'pending', $3, $4, 'GHS')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(user_id), reference, amount]
    )

    Repo.query!(
      """
      INSERT INTO public.payment_attempts (
        id, booking_id, reference, request_fingerprint, status, amount_minor, currency, expires_at
      ) VALUES ($1, $2, $3, $4, 'ready', $5, 'GHS', now() + interval '15 minutes')
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(booking_id),
        reference,
        "fp-#{reference}",
        amount
      ]
    )

    {booking_id, reference}
  end

  defp recreate_tables do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate Paystack fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["booking_refunds", "payment_attempts", "bookings", "users"] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

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
  end
end
