defmodule Mithril.PaystackPayoutLoanRecoveryTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.DirectWorkerLoans
  alias Mithril.MobileFunctions.PaystackPayout
  alias Mithril.Repo

  @recipient "RCP_test123"

  setup do
    Fixtures.checkout!()
    install_payout_schema!()

    previous_req = Application.get_env(:mithril, :paystack_req_options)

    on_exit(fn ->
      if previous_req do
        Application.put_env(:mithril, :paystack_req_options, previous_req)
      else
        Application.delete_env(:mithril, :paystack_req_options)
      end
    end)

    :ok
  end

  test "Paystack withdrawals recover outstanding loans before transferring the net" do
    {worker_id, reference} = funded_worker_with_loan!(40_000, extra_minor: 50_000)
    {:ok, body_agent} = Agent.start_link(fn -> nil end)
    stub_paystack_transfer!(body_agent, 50_000, reference)

    assert {:ok, %{ok: true, data: data}} =
             PaystackPayout.initiate_transfer(worker_id, %{
               "amount" => 90_000,
               "recipient" => @recipient,
               "reference" => reference,
               "currency" => "GHS"
             })

    assert Agent.get(body_agent, & &1)["amount"] == 50_000
    assert data["transfer_code"] == "TRF_loan_net"

    assert {:ok, %{"outstandingMinor" => 0}} = DirectWorkerLoans.worker_summary(worker_id)

    [[started_amount]] =
      Repo.query!("SELECT amount FROM public.withdrawal_starts").rows

    assert started_amount == 50_000

    [[payout_amount, metadata]] =
      Repo.query!("SELECT amount, metadata FROM public.cleaner_payouts").rows

    assert payout_amount == 50_000
    assert metadata["requested_amount"] == 90_000
    assert metadata["loan_recovery_minor"] == 40_000
    assert metadata["net_amount"] == 50_000

    assert {:ok, %{ok: true, data: reused}} =
             PaystackPayout.initiate_transfer(worker_id, %{
               "amount" => 90_000,
               "recipient" => @recipient,
               "reference" => reference,
               "currency" => "GHS"
             })

    assert reused["domain"] == "reused"
    assert reused["amount"] == 50_000
    assert Agent.get(body_agent, & &1)["amount"] == 50_000
  end

  test "Paystack withdrawals that are fully recovered skip the transfer" do
    {worker_id, reference} = funded_worker_with_loan!(40_000)
    {:ok, body_agent} = Agent.start_link(fn -> :not_called end)
    stub_paystack_transfer!(body_agent, 0, reference)

    assert {:ok, %{ok: true, data: data}} =
             PaystackPayout.initiate_transfer(worker_id, %{
               "amount" => 40_000,
               "recipient" => @recipient,
               "reference" => reference,
               "currency" => "GHS"
             })

    assert data["domain"] == "loan_recovery"
    assert data["amount"] == 0
    assert data["loan_recovery_minor"] == 40_000
    assert Agent.get(body_agent, & &1) == :not_called

    assert {:ok, %{"outstandingMinor" => 0}} = DirectWorkerLoans.worker_summary(worker_id)
    assert Repo.query!("SELECT count(*) FROM public.withdrawal_starts").rows == [[0]]

    [[payout_amount, payout_status]] =
      Repo.query!("SELECT amount, status::text FROM public.cleaner_payouts").rows

    assert payout_amount == 0
    assert payout_status == "success"

    [[balance]] =
      Repo.query!("SELECT balance_subunit FROM public.wallets").rows

    assert balance == 0

    assert {:ok, %{ok: true, data: reused}} =
             PaystackPayout.initiate_transfer(worker_id, %{
               "amount" => 40_000,
               "recipient" => @recipient,
               "reference" => reference,
               "currency" => "GHS"
             })

    assert reused["domain"] == "reused"
    assert reused["amount"] == 0
    assert Agent.get(body_agent, & &1) == :not_called
  end

  test "Paystack withdrawals roll back when net after recovery is below the minimum" do
    {worker_id, reference} = funded_worker_with_loan!(48_000, extra_minor: 2_000)

    assert {:error,
            {:status, 400,
             %{ok: false, error: "After loan recovery, remaining withdrawal is below GHS 50.00"}}} =
             PaystackPayout.initiate_transfer(worker_id, %{
               "amount" => 50_000,
               "recipient" => @recipient,
               "reference" => reference,
               "currency" => "GHS"
             })

    assert {:ok, %{"outstandingMinor" => 48_000}} = DirectWorkerLoans.worker_summary(worker_id)

    [[balance]] =
      Repo.query!("SELECT balance_subunit FROM public.wallets").rows

    assert balance == 50_000
    assert Repo.query!("SELECT count(*) FROM public.withdrawal_starts").rows == [[0]]
  end

  test "Paystack withdrawals with no outstanding loan still transfer the requested amount" do
    {worker_id, reference} = funded_worker_with_loan!(0, extra_minor: 50_000)
    {:ok, body_agent} = Agent.start_link(fn -> nil end)
    stub_paystack_transfer!(body_agent, 50_000, reference)

    assert {:ok, %{ok: true}} =
             PaystackPayout.initiate_transfer(worker_id, %{
               "amount" => 50_000,
               "recipient" => @recipient,
               "reference" => reference,
               "currency" => "GHS"
             })

    assert Agent.get(body_agent, & &1)["amount"] == 50_000
    assert {:ok, %{"outstandingMinor" => 0}} = DirectWorkerLoans.worker_summary(worker_id)

    [[started_amount]] =
      Repo.query!("SELECT amount FROM public.withdrawal_starts").rows

    assert started_amount == 50_000
  end

  defp funded_worker_with_loan!(loan_minor, opts \\ []) do
    extra_minor = Keyword.get(opts, :extra_minor, 0)
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    worker_uid = Ecto.UUID.dump!(worker_id)
    reference = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'cleaner')",
      [worker_uid]
    )

    Repo.query!(
      """
      INSERT INTO public.payout_methods (user_id, recipient_code, currency)
      VALUES ($1, $2, 'GHS')
      """,
      [worker_uid, @recipient]
    )

    if loan_minor > 0 do
      assert {:ok, created} =
               DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => loan_minor})

      assert {:ok, _} =
               DirectWorkerLoans.review(admin_id, created["id"], %{"decision" => "approve"})
    else
      Repo.query!(
        """
        INSERT INTO public.wallets (user_id, balance_subunit, currency)
        VALUES ($1, 0, 'GHS')
        ON CONFLICT (user_id) DO NOTHING
        """,
        [worker_uid]
      )
    end

    if extra_minor > 0 do
      Repo.query!(
        """
        INSERT INTO public.wallets (user_id, balance_subunit, currency)
        VALUES ($1, $2, 'GHS')
        ON CONFLICT (user_id) DO UPDATE
        SET balance_subunit = public.wallets.balance_subunit + EXCLUDED.balance_subunit
        """,
        [worker_uid, extra_minor]
      )
    end

    {worker_id, reference}
  end

  defp stub_paystack_transfer!(agent, amount, reference) do
    Req.Test.stub(Mithril.MobileFunctions.Paystack, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      Agent.update(agent, fn _ -> Jason.decode!(raw) end)

      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{
          "status" => "pending",
          "transfer_code" => "TRF_loan_net",
          "id" => 11,
          "amount" => amount,
          "currency" => "GHS",
          "recipient" => @recipient,
          "reference" => reference
        }
      })
    end)

    Application.put_env(:mithril, :paystack_req_options,
      plug: {Req.Test, Mithril.MobileFunctions.Paystack}
    )
  end

  defp install_payout_schema! do
    Repo.query!("ALTER TABLE public.cleaner_data ADD COLUMN IF NOT EXISTS status text")
    Repo.query!("ALTER TABLE public.cleaner_data ADD COLUMN IF NOT EXISTS verified boolean")
    Repo.query!("UPDATE public.cleaner_data SET status = 'active', verified = true")
    Repo.query!("ALTER TABLE public.cleaner_data ALTER COLUMN status SET DEFAULT 'active'")
    Repo.query!("ALTER TABLE public.cleaner_data ALTER COLUMN verified SET DEFAULT true")

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.kyc_profiles (
      user_id uuid,
      kyc_status text,
      review_answer text,
      updated_at timestamptz,
      sumsub_applicant_id text,
      last_event_type text,
      submitted_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.payout_methods (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      recipient_code text NOT NULL,
      currency text DEFAULT 'GHS'
    )
    """)

    Repo.query!("""
    DO $enum$
    BEGIN
      CREATE TYPE public.withdrawal_status AS ENUM ('pending', 'processing', 'success', 'failed');
    EXCEPTION
      WHEN duplicate_object THEN NULL;
    END
    $enum$;
    """)

    Repo.query!("DROP TABLE IF EXISTS public.cleaner_payouts")

    Repo.query!("""
    CREATE TABLE public.cleaner_payouts (
      user_id uuid NOT NULL,
      recipient_code text NOT NULL,
      amount integer NOT NULL,
      currency text NOT NULL,
      reference uuid PRIMARY KEY,
      reason text,
      status public.withdrawal_status NOT NULL,
      metadata jsonb,
      paystack_transfer_code text,
      paystack_transfer_id bigint,
      error_message text,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("DROP TABLE IF EXISTS public.withdrawal_starts")

    Repo.query!("""
    CREATE TABLE public.withdrawal_starts (
      worker_id uuid NOT NULL,
      amount integer NOT NULL,
      withdrawal_id uuid NOT NULL,
      recipient text,
      payout_method_id uuid
    )
    """)

    Repo.query!("DROP FUNCTION IF EXISTS public.get_my_wallet_balance() CASCADE")

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.get_my_wallet_balance()
    RETURNS TABLE(balance integer, currency text)
    LANGUAGE sql
    STABLE
    AS $function$
      SELECT w.balance_subunit, COALESCE(w.currency, 'GHS')
      FROM public.wallets w
      WHERE w.user_id = NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
    $function$;
    """)

    Repo.query!(
      "DROP FUNCTION IF EXISTS public.fn_begin_cleaner_withdrawal(uuid, integer, uuid, text, uuid) CASCADE"
    )

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.fn_begin_cleaner_withdrawal(
      p_worker_id uuid,
      p_amount integer,
      p_withdrawal_id uuid,
      p_recipient text,
      p_payout_method_id uuid
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF p_amount < 5000 THEN
        RAISE EXCEPTION 'below_minimum_withdrawal';
      END IF;

      UPDATE public.wallets
      SET balance_subunit = balance_subunit - p_amount, updated_at = now()
      WHERE user_id = p_worker_id AND balance_subunit >= p_amount;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'insufficient_balance';
      END IF;

      INSERT INTO public.withdrawal_starts (
        worker_id, amount, withdrawal_id, recipient, payout_method_id
      ) VALUES (
        p_worker_id, p_amount, p_withdrawal_id, p_recipient, p_payout_method_id
      );
    END
    $function$;
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.fn_finalize_withdrawal(
      p_reference text,
      p_status public.withdrawal_status,
      p_error text,
      p_transfer_code text
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      NULL;
    END
    $function$;
    """)
  end
end
