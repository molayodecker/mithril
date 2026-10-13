defmodule Mithril.DirectAdminMoneyFixtures do
  @moduledoc false

  alias Mithril.Repo

  @schema_root Path.expand("../../priv/repo/sql/direct", __DIR__)

  def checkout! do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate money fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "worker_loan_events",
          "worker_loan_requests",
          "worker_loan_accounts",
          "admin_billing_invoices",
          "admin_payment_advices",
          "job_invoices",
          "admin_wallet_credits",
          "wallet_transactions",
          "wallets",
          "whatsapp_inbox_messages",
          "cleaner_data",
          "bookings",
          "user_roles",
          "profiles",
          "users"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("DROP SEQUENCE IF EXISTS public.job_invoice_no_seq")
    Repo.query!("DROP SEQUENCE IF EXISTS public.payment_advice_no_seq")

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text
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
      customer_id uuid NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY
    )
    """)

    Repo.query!("""
    CREATE TABLE public.wallets (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL UNIQUE REFERENCES public.users(id),
      balance_subunit integer NOT NULL DEFAULT 0,
      currency varchar(3) NOT NULL DEFAULT 'GHS',
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.wallet_transactions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      wallet_id uuid NOT NULL REFERENCES public.wallets(id),
      booking_id uuid,
      amount_subunit integer NOT NULL,
      type text NOT NULL,
      description text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.admin_wallet_credits (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      worker_id uuid NOT NULL REFERENCES public.users(id),
      amount_subunit integer NOT NULL CHECK (amount_subunit > 0),
      currency varchar(3) NOT NULL DEFAULT 'GHS',
      notes text,
      recorded_by uuid NOT NULL REFERENCES public.users(id),
      wallet_transaction_id uuid NOT NULL REFERENCES public.wallet_transactions(id),
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE SEQUENCE public.job_invoice_no_seq AS integer
    """)

    Repo.query!("""
    CREATE TABLE public.job_invoices (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL UNIQUE REFERENCES public.bookings(id) ON DELETE CASCADE,
      public_token text NOT NULL UNIQUE,
      invoice_no text NOT NULL,
      issued_on date NOT NULL,
      bill_to_name text NOT NULL,
      bill_to_address text,
      bill_to_phone text,
      bill_to_email text,
      project text NOT NULL,
      lines jsonb NOT NULL,
      adjustment_minor integer NOT NULL DEFAULT 0,
      subtotal_minor integer NOT NULL CHECK (subtotal_minor >= 0),
      total_minor integer NOT NULL,
      currency varchar(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
      notes text,
      signatory_role text,
      created_by uuid NOT NULL REFERENCES public.users(id),
      updated_by uuid REFERENCES public.users(id),
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      last_whatsapp_sent_at timestamptz,
      last_email_sent_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.whatsapp_inbox_messages (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      direction text NOT NULL,
      phone_e164 text NOT NULL,
      body text NOT NULL,
      user_id uuid,
      sent_by_user_id uuid,
      business_phone_e164 text,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.admin_cash_payout_recorder_is_allowed(p_user_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$
      SELECT EXISTS (
        SELECT 1
        FROM public.users u
        JOIN public.user_roles r ON r.user_id = u.id
        WHERE u.id = p_user_id AND r.role_id = 'admin'
      );
    $$
    """)

    install_function!(
      "20261012160000_admin_record_wallet_credit.sql",
      "record_admin_wallet_credit"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.worker_loan_accounts (
      worker_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
      outstanding_minor integer NOT NULL DEFAULT 0 CHECK (outstanding_minor >= 0),
      currency varchar(3) NOT NULL DEFAULT 'GHS',
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.worker_loan_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      worker_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
      amount_minor integer NOT NULL CHECK (amount_minor > 0),
      reason text,
      status text NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
      reviewed_by uuid REFERENCES public.users(id),
      review_notes text,
      reviewed_at timestamptz,
      wallet_transaction_id uuid REFERENCES public.wallet_transactions(id),
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS worker_loan_requests_one_pending_per_worker_idx
      ON public.worker_loan_requests (worker_id)
      WHERE status = 'pending'
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.worker_loan_events (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      worker_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
      request_id uuid REFERENCES public.worker_loan_requests(id),
      event_type text NOT NULL CHECK (event_type IN ('disbursement', 'repayment')),
      amount_minor integer NOT NULL CHECK (amount_minor > 0),
      outstanding_after_minor integer NOT NULL CHECK (outstanding_after_minor >= 0),
      wallet_transaction_id uuid REFERENCES public.wallet_transactions(id),
      recorded_by uuid REFERENCES public.users(id),
      notes text,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    for name <- ["create_worker_loan_request", "review_worker_loan_request"] do
      install_function!("20261013190000_worker_loan_requests.sql", name)
    end

    install_function!("20261013200000_worker_loan_recovery.sql", "apply_worker_loan_recovery")

    install_function!("20261012180000_admin_job_invoices.sql", "upsert_admin_job_invoice")

    Repo.query!("""
    CREATE SEQUENCE public.payment_advice_no_seq AS integer
    """)

    Repo.query!("""
    CREATE TABLE public.admin_billing_invoices (
      id uuid PRIMARY KEY,
      form_type text CHECK (form_type IS NULL OR form_type IN ('w8ben', '1099')),
      invoice_no text NOT NULL,
      issued_on date NOT NULL,
      bill_to_name text NOT NULL,
      bill_to_address text,
      bill_to_phone text,
      bill_to_email text,
      project text NOT NULL,
      lines jsonb NOT NULL,
      adjustment_minor integer NOT NULL DEFAULT 0,
      subtotal_minor integer NOT NULL CHECK (subtotal_minor >= 0),
      total_minor integer NOT NULL,
      currency varchar(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
      notes text,
      signatory_role text,
      created_by uuid NOT NULL REFERENCES public.users(id),
      updated_by uuid REFERENCES public.users(id),
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.admin_payment_advices (
      id uuid PRIMARY KEY,
      form_type text NOT NULL CHECK (form_type IN ('w8ben', '1099')),
      advice_no text NOT NULL,
      pay_period text NOT NULL,
      payment_date date NOT NULL,
      paid_to_name text NOT NULL,
      paid_to_address text,
      paid_to_email text,
      paid_to_phone text,
      employee_id text,
      role_name text,
      department text,
      pay_type text,
      earnings jsonb NOT NULL,
      reimbursements jsonb NOT NULL,
      deductions jsonb NOT NULL,
      earnings_minor integer NOT NULL CHECK (earnings_minor >= 0),
      reimbursements_minor integer NOT NULL CHECK (reimbursements_minor >= 0),
      deductions_minor integer NOT NULL CHECK (deductions_minor >= 0),
      net_minor integer NOT NULL,
      currency varchar(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
      pay_method text,
      pay_account text,
      pay_network text,
      pay_reference text,
      created_by uuid NOT NULL REFERENCES public.users(id),
      updated_by uuid REFERENCES public.users(id),
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    install_function!(
      "20261012200000_admin_billing_documents.sql",
      "upsert_admin_billing_invoice"
    )

    install_function!("20261012200000_admin_billing_documents.sql", "upsert_admin_payment_advice")
  end

  def insert_user!(role \\ nil) do
    id = Ecto.UUID.generate()
    uid = Ecto.UUID.dump!(id)

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      uid,
      "#{id}@example.com",
      nil
    ])

    if role do
      Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, $2)", [uid, role])
    end

    id
  end

  def insert_worker! do
    id = insert_user!()
    Repo.query!("INSERT INTO public.cleaner_data (user_id) VALUES ($1)", [Ecto.UUID.dump!(id)])
    id
  end

  def insert_booking!(customer_id) do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.bookings (id, customer_id) VALUES ($1, $2)", [
      Ecto.UUID.dump!(id),
      Ecto.UUID.dump!(customer_id)
    ])

    id
  end

  defp install_function!(filename, name) do
    sql = File.read!(Path.join(@schema_root, filename))

    case Regex.run(
           ~r/CREATE OR REPLACE FUNCTION public\.#{name}\b.*?\$function\$;/s,
           sql
         ) do
      [function] -> Repo.query!(function)
      _ -> raise "Could not load #{name} from #{filename}"
    end
  end
end
