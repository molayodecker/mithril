defmodule Mithril.WalletCreditNotificationsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.WalletCreditNotifications

  setup do
    :ok = Sandbox.checkout(Repo)
    ensure_tables!()
    :ok
  end

  test "formats a job credit and a wallet add" do
    assert WalletCreditNotifications.amount_label(20_000, "GHS") == "GHS 200.00"
    assert WalletCreditNotifications.amount_label(123_456, nil) == "GHS 1,234.56"

    assert WalletCreditNotifications.message(20_000, "GHS", nil) ==
             "GHS 200.00 was added to your Instaclean wallet."

    assert WalletCreditNotifications.message(20_000, "GHS", Ecto.UUID.generate()) ==
             "GHS 200.00 from a completed job was added to your wallet."
  end

  test "skips debits and withdrawal refunds" do
    refute WalletCreditNotifications.notifiable_credit?(%{
             type: "debit",
             amount_subunit: 20_000,
             withdrawal_request_id: nil
           })

    refute WalletCreditNotifications.notifiable_credit?(%{
             type: "credit",
             amount_subunit: 20_000,
             withdrawal_request_id: Ecto.UUID.generate()
           })

    refute WalletCreditNotifications.notifiable_credit?(%{
             type: "credit",
             amount_subunit: 0,
             withdrawal_request_id: nil
           })

    assert WalletCreditNotifications.notifiable_credit?(%{
             type: "credit",
             amount_subunit: 20_000,
             withdrawal_request_id: nil
           })
  end

  test "writes one inbox row and one WhatsApp for a new credit" do
    parent = self()
    user_id = Ecto.UUID.generate()
    transaction_id = insert_credit!(user_id, 20_000, nil, nil)

    assert :ok =
             WalletCreditNotifications.run(
               whatsapp_sender: fn credit ->
                 send(parent, {:whatsapp, credit})
                 :sent
               end
             )

    assert_receive {:whatsapp, whatsapp}
    assert whatsapp.phone == "+233200000001"
    assert whatsapp.name == "Ama Cleaner"
    assert whatsapp.message == "GHS 200.00 was added to your Instaclean wallet."

    [[title, message, type, dedupe_key, data]] =
      Repo.query!(
        """
        SELECT title, message, type::text, dedupe_key, data
        FROM public.notifications
        WHERE user_id = $1::uuid
        """,
        [dump!(user_id)]
      ).rows

    assert title == "Money added to your wallet"
    assert message == "GHS 200.00 was added to your Instaclean wallet."
    assert type == "wallet_credited"
    assert dedupe_key == "wallet_credit:#{transaction_id}"
    data = if is_binary(data), do: Jason.decode!(data), else: data
    assert data["screen"] == "/(tabs)/wallet"
    assert data["walletTransactionId"] == transaction_id
    assert data["amountSubunit"] == 20_000

    assert :ok =
             WalletCreditNotifications.run(
               whatsapp_sender: fn credit ->
                 if credit.user_id == user_id, do: flunk("duplicate WhatsApp")
               end
             )

    refute_received {:whatsapp, _}
  end

  test "recovers WhatsApp when inbox exists but delivery ledger is missing" do
    parent = self()
    user_id = Ecto.UUID.generate()
    transaction_id = insert_credit!(user_id, 20_000, nil, nil)

    Repo.query!(
      """
      INSERT INTO public.notifications (user_id, type, title, message, read, dedupe_key, data)
      VALUES ($1::uuid, 'wallet_credited', 'Existing credit', 'Existing inbox', false, $2, '{}'::jsonb)
      """,
      [dump!(user_id), "wallet_credit:#{transaction_id}"]
    )

    assert :ok =
             WalletCreditNotifications.run(
               whatsapp_sender: fn credit ->
                 send(parent, {:recovered, credit.transaction_id})
                 :sent
               end
             )

    assert_receive {:recovered, ^transaction_id}
    assert Repo.query!(
             "SELECT count(*) FROM public.notifications WHERE user_id = $1::uuid",
             [dump!(user_id)]
           ).rows == [[1]]
  end

  test "prioritizes new inbox notifications over an expired WhatsApp retry backlog" do
    parent = self()

    for _ <- 1..51 do
      user_id = Ecto.UUID.generate()
      transaction_id = insert_credit!(user_id, 1_000, nil, nil)

      Repo.query!(
        """
        INSERT INTO public.notifications (user_id, type, title, message, read, dedupe_key, data)
        VALUES ($1::uuid, 'wallet_credited', 'Old credit', 'Retry pending', false, $2, '{}'::jsonb)
        """,
        [dump!(user_id), "wallet_credit:#{transaction_id}"]
      )

      Repo.query!(
        """
        INSERT INTO public.wallet_credit_whatsapp_delivery (transaction_id, next_attempt_at)
        VALUES ($1::uuid, now() - interval '1 minute')
        """,
        [dump!(transaction_id)]
      )
    end

    new_user = Ecto.UUID.generate()
    new_transaction = insert_credit!(new_user, 2_000, nil, nil)

    assert :ok =
             WalletCreditNotifications.run(
               whatsapp_sender: fn credit ->
                 send(parent, {:delivered, credit.transaction_id})
                 :sent
               end
             )

    assert_received {:delivered, ^new_transaction}
    assert Repo.query!(
             "SELECT count(*) FROM public.notifications WHERE user_id = $1::uuid",
             [dump!(new_user)]
           ).rows == [[1]]
  end

  test "uses the completed-job copy when the credit belongs to a booking" do
    parent = self()
    user_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()
    insert_credit!(user_id, 15_050, booking_id, nil)

    assert :ok =
             WalletCreditNotifications.run(
               whatsapp_sender: fn credit ->
                 send(parent, {:whatsapp, credit.message})
                 :sent
               end
             )

    assert_receive {:whatsapp, "GHS 150.50 from a completed job was added to your wallet."}
  end

  test "does not notify a debit or a withdrawal refund" do
    user_id = Ecto.UUID.generate()
    insert_credit!(user_id, 5_000, nil, Ecto.UUID.generate(), "credit")
    insert_credit!(user_id, 5_000, nil, nil, "debit")

    assert :ok =
             WalletCreditNotifications.run(
               whatsapp_sender: fn credit ->
                 if credit.user_id == user_id, do: flunk("notified")
               end
             )

    assert Repo.query!(
             "SELECT count(*) FROM public.notifications WHERE user_id = $1::uuid",
             [dump!(user_id)]
           ).rows == [[0]]
  end

  defp insert_credit!(
         user_id,
         amount_subunit,
         booking_id,
         withdrawal_request_id,
         type \\ "credit"
       ) do
    transaction_id = Ecto.UUID.generate()
    wallet_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.users (id, phone)
      VALUES ($1::uuid, '+233200000001')
      ON CONFLICT (id) DO NOTHING
      """,
      [dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.profiles (id, fullname, firstname)
      VALUES ($1::uuid, 'Ama Cleaner', 'Ama')
      ON CONFLICT (id) DO NOTHING
      """,
      [dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.wallets (id, user_id, currency)
      VALUES ($1::uuid, $2::uuid, 'GHS')
      """,
      [dump!(wallet_id), dump!(user_id)]
    )

    Repo.query!(
      """
      INSERT INTO public.wallet_transactions (
        id, wallet_id, booking_id, amount_subunit, type, withdrawal_request_id, created_at
      ) VALUES (
        $1::uuid, $2::uuid, $3::uuid, $4, $5, $6::uuid, now()
      )
      """,
      [
        dump!(transaction_id),
        dump!(wallet_id),
        dump_optional(booking_id),
        amount_subunit,
        type,
        dump_optional(withdrawal_request_id)
      ]
    )

    transaction_id
  end

  defp ensure_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to create wallet fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.wallet_credit_notification_settings (
      id boolean PRIMARY KEY,
      activated_at timestamptz NOT NULL
    )
    """)

    Repo.query!("""
    INSERT INTO public.wallet_credit_notification_settings (id, activated_at)
    VALUES (true, '2000-01-01'::timestamptz)
    ON CONFLICT (id) DO UPDATE SET activated_at = EXCLUDED.activated_at
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.wallet_credit_whatsapp_delivery (
      transaction_id uuid PRIMARY KEY,
      sent_at timestamptz,
      next_attempt_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.users (
      id uuid PRIMARY KEY,
      phone text
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      user_id uuid
    )
    """)

    Repo.query!("ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS user_id uuid")
    Repo.query!("ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS fullname text")
    Repo.query!("ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS firstname text")

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.wallets (
      id uuid PRIMARY KEY,
      user_id uuid,
      currency text
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.wallet_transactions (
      id uuid PRIMARY KEY,
      wallet_id uuid,
      booking_id uuid,
      amount_subunit integer,
      type text,
      withdrawal_request_id uuid,
      created_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.notifications (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      type text,
      title text,
      message text,
      read boolean,
      dedupe_key text,
      data jsonb
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS notifications_user_dedupe_key_uniq
    ON public.notifications (user_id, dedupe_key)
    WHERE dedupe_key IS NOT NULL
    """)
  end

  defp dump!(value) do
    {:ok, binary} = Ecto.UUID.dump(value)
    binary
  end

  defp dump_optional(nil), do: nil
  defp dump_optional(value), do: dump!(value)
end
