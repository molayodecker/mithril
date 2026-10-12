defmodule Mithril.DirectAdminMoneyFixtures do
  @moduledoc false

  alias Mithril.Repo

  @schema_root Path.expand("../../../instaclean-schema/migrations", __DIR__)

  def checkout! do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate money fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
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

    install_function!("20261012180000_admin_job_invoices.sql", "upsert_admin_job_invoice")
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
