defmodule Mithril.DirectAdminWalletsTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.DirectAdminWallets
  alias Mithril.Repo

  setup do
    Fixtures.checkout!()
    :ok
  end

  test "an admin credit creates a wallet and later credits add to the balance" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:error, :worker_not_found} = DirectAdminWallets.show(admin_id, Ecto.UUID.generate())

    assert {:ok, %{"balanceMinor" => nil, "currency" => "GHS"}} =
             DirectAdminWallets.show(admin_id, worker_id)

    assert {:ok, first} =
             DirectAdminWallets.credit(admin_id, worker_id, %{
               "amountMinor" => 5_000,
               "notes" => "  Transport float  "
             })

    assert first["amountMinor"] == 5_000
    assert first["newBalanceMinor"] == 5_000
    assert first["currency"] == "GHS"

    assert {:ok, %{"balanceMinor" => 5_000, "currency" => "GHS"}} =
             DirectAdminWallets.show(admin_id, worker_id)

    assert {:ok, second} =
             DirectAdminWallets.credit(admin_id, worker_id, %{"amountMinor" => "2500"})

    assert second["newBalanceMinor"] == 7_500

    [[balance]] = Repo.query!("SELECT balance_subunit FROM public.wallets").rows
    assert balance == 7_500

    assert Repo.query!(
             "SELECT type, booking_id, description FROM public.wallet_transactions ORDER BY amount_subunit DESC"
           ).rows == [
             ["credit", nil, "Admin wallet credit — Transport float"],
             ["credit", nil, "Admin wallet credit"]
           ]

    assert Repo.query!(
             "SELECT notes FROM public.admin_wallet_credits ORDER BY amount_subunit DESC"
           ).rows ==
             [
               ["Transport float"],
               [nil]
             ]
  end

  test "wallet credits reject the wrong person, the wrong amount, and a non-cedi wallet" do
    admin_id = Fixtures.insert_user!("admin")
    reviewer_id = Fixtures.insert_user!("reviewer")
    stranger_id = Fixtures.insert_user!()
    worker_id = Fixtures.insert_worker!()
    customer_id = Fixtures.insert_user!()

    assert {:error, :forbidden} =
             DirectAdminWallets.credit(stranger_id, worker_id, %{"amountMinor" => 1_000})

    assert {:error, %Postgrex.Error{postgres: %{message: unbound}}} =
             Repo.query(
               """
               SELECT public.record_admin_wallet_credit($1::uuid, $2::integer, $3::uuid, $4::text)
               """,
               [Ecto.UUID.dump!(worker_id), 1_000, Ecto.UUID.dump!(admin_id), nil]
             )

    assert unbound =~ "recorded_by_not_authorized"

    assert {:error, :forbidden} =
             DirectAdminWallets.credit(reviewer_id, worker_id, %{"amountMinor" => 1_000})

    assert {:error, :invalid_amount} =
             DirectAdminWallets.credit(admin_id, worker_id, %{"amountMinor" => 0})

    assert {:error, :invalid_amount} =
             DirectAdminWallets.credit(admin_id, worker_id, %{"amountMinor" => -1})

    assert {:error, :invalid_notes} =
             DirectAdminWallets.credit(admin_id, worker_id, %{
               "amountMinor" => 1_000,
               "notes" => String.duplicate("a", 501)
             })

    assert {:error, :worker_not_found} =
             DirectAdminWallets.credit(admin_id, customer_id, %{"amountMinor" => 1_000})

    assert {:error, :invalid_request} = DirectAdminWallets.show("nope", worker_id)

    assert {:ok, _} = DirectAdminWallets.credit(admin_id, worker_id, %{"amountMinor" => 100})

    Repo.query!("UPDATE public.wallets SET currency = 'USD' WHERE user_id = $1", [
      Ecto.UUID.dump!(worker_id)
    ])

    assert {:error, :unsupported_currency} =
             DirectAdminWallets.credit(admin_id, worker_id, %{"amountMinor" => 100})

    Repo.query!(
      "UPDATE public.wallets SET currency = 'GHS', balance_subunit = 2147483647 WHERE user_id = $1",
      [
        Ecto.UUID.dump!(worker_id)
      ]
    )

    assert {:error, :amount_too_large} =
             DirectAdminWallets.credit(admin_id, worker_id, %{"amountMinor" => 1})

    [[balance]] =
      Repo.query!("SELECT balance_subunit FROM public.wallets WHERE user_id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    assert balance == 2_147_483_647
  end
end
