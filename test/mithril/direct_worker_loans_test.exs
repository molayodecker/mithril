defmodule Mithril.DirectWorkerLoansTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.DirectWorkerLoans
  alias Mithril.Repo

  setup do
    Fixtures.checkout!()
    :ok
  end

  test "worker requests a loan and admin approves with wallet credit" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:ok, %{"status" => "pending", "amountMinor" => 25_000}} =
             DirectWorkerLoans.create_request(worker_id, %{
               "amountMinor" => 25_000,
               "reason" => "Transport to site"
             })

    assert {:error, :pending_request_exists} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 1_000})

    assert {:ok, [pending]} = DirectWorkerLoans.list_admin_requests(admin_id)
    assert pending["amountMinor"] == 25_000
    assert pending["reason"] == "Transport to site"

    request_id = pending["id"]

    assert {:ok, approved} =
             DirectWorkerLoans.review(admin_id, request_id, %{
               "decision" => "approve",
               "reviewNotes" => "Approved for travel"
             })

    assert approved["status"] == "approved"
    assert approved["newBalanceMinor"] == 25_000
    assert approved["outstandingMinor"] == 25_000

    assert {:ok, %{"outstandingMinor" => 25_000}} = DirectWorkerLoans.worker_summary(worker_id)

    assert {:ok, requests} = DirectWorkerLoans.list_worker_requests(worker_id)
    assert hd(requests)["status"] == "approved"

    [[balance]] = Repo.query!("SELECT balance_subunit FROM public.wallets").rows
    assert balance == 25_000
  end

  test "admin can reject a pending request" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 10_000})

    assert {:ok, rejected} =
             DirectWorkerLoans.review(admin_id, created["id"], %{
               "decision" => "reject",
               "reviewNotes" => "Not now"
             })

    assert rejected["status"] == "rejected"

    assert {:ok, _} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 5_000})
  end

  test "loan recovery reduces net payout and outstanding balance" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    worker_uid = Ecto.UUID.dump!(worker_id)
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 40_000})

    assert {:ok, _} =
             DirectWorkerLoans.review(admin_id, created["id"], %{"decision" => "approve"})

    assert {:ok, recovery} =
             Mithril.DirectAdminActor.with_actor(admin_id, fn ->
               case Mithril.Repo.query(
                      """
                      SELECT public.apply_worker_loan_recovery(
                        $1::uuid, $2::integer, $3::uuid, 'test', $4::uuid
                      )
                      """,
                      [worker_uid, 50_000, Ecto.UUID.dump!(admin_id), Ecto.UUID.dump!(booking_id)]
                    ) do
                 {:ok, %{rows: [[payload]]}} -> payload
                 {:error, error} -> Mithril.Repo.rollback(error)
               end
             end)

    assert recovery["grossMinor"] == 50_000
    assert recovery["recoveryMinor"] == 40_000
    assert recovery["netMinor"] == 10_000
    assert recovery["outstandingMinor"] == 0
  end

  test "strangers cannot review or impersonate workers" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    stranger_id = Fixtures.insert_user!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 3_000})

    assert {:error, :forbidden} =
             DirectWorkerLoans.review(stranger_id, created["id"], %{"decision" => "approve"})

    assert {:error, :worker_not_found} = DirectWorkerLoans.list_worker_requests(stranger_id)
  end
end
