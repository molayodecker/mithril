defmodule Mithril.DirectContractsTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.DirectContracts
  alias Mithril.DirectContracts.Calendar
  alias Mithril.Repo

  setup do
    Fixtures.checkout!()
    install_contracts!()
    :ok
  end

  test "a weekly advance credits the wallet, payday pays the remainder, and the loan book stays empty" do
    admin_id = Fixtures.insert_user!("admin")
    stranger_id = Fixtures.insert_user!("reviewer")
    today = Date.utc_today()
    weekday = if Date.day_of_week(today) == 7, do: 0, else: Date.day_of_week(today)
    week = today

    worker_id = named_worker!("Ama Owusu")
    other_id = named_worker!("Abena Asante")

    assert {:error, :forbidden} =
             DirectContracts.create(stranger_id, %{
               "name" => "Kofi Mensah Holdings",
               "kind" => "company",
               "monthlyFeeMinor" => 400_000
             })

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Kofi Mensah Holdings",
               "kind" => "company",
               "billingContact" => "Esi Mensah",
               "phone" => "+233245550142",
               "email" => "accounts@kmholdings.com.gh",
               "monthlyFeeMinor" => 400_000
             })

    assert {:ok, %{"id" => ama_id}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 120_000,
               "clientRateMinor" => 200_000,
               "weeklyAdvanceMinor" => 20_000,
               "advanceWeekday" => weekday,
               "advanceMode" => "automatic"
             })

    assert {:ok, _} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => other_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 130_000,
               "clientRateMinor" => 200_000,
               "weeklyAdvanceMinor" => 20_000,
               "advanceWeekday" => weekday,
               "advanceMode" => "manual"
             })

    assert :ok = DirectContracts.pay_automatic_advances()

    assert {:ok, %{"paidCount" => 0, "totalMinor" => 0}} =
             DirectContracts.pay_automatic_advances() |> normalize_automatic()

    assert {:error, :advance_already_paid} =
             DirectContracts.pay_advance(admin_id, contract_id, %{
               "assignmentId" => ama_id,
               "weekOn" => Date.to_iso8601(week)
             })

    [[balance]] =
      Repo.query!("SELECT balance_subunit FROM public.wallets WHERE user_id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    assert balance == 20_000
    assert Repo.query!("SELECT count(*) FROM public.worker_loan_accounts").rows == [[0]]

    month = Calendar.month_key(Calendar.period_start(today))

    assert {:ok, payday} = DirectContracts.run_payday(admin_id, contract_id, %{"month" => month})
    assert payday["totalNetMinor"] == 120_000 - 20_000 + 130_000

    assert {:error, :payday_already_run} =
             DirectContracts.run_payday(admin_id, contract_id, %{"month" => month})

    [[balance]] =
      Repo.query!("SELECT balance_subunit FROM public.wallets WHERE user_id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    assert balance == 120_000

    assert {:ok, _} =
             DirectContracts.update_assignment(admin_id, contract_id, ama_id, %{
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 120_000,
               "clientRateMinor" => 1,
               "weeklyAdvanceMinor" => 20_000,
               "advanceWeekday" => weekday,
               "advanceMode" => "automatic"
             })

    assert {:error, :client_rates_mismatch} =
             DirectContracts.send_invoice(admin_id, contract_id, %{
               "month" => month,
               "style" => "per_worker",
               "channel" => "email"
             })

    assert {:ok, _} =
             DirectContracts.update_assignment(admin_id, contract_id, ama_id, %{
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 120_000,
               "clientRateMinor" => 200_000,
               "weeklyAdvanceMinor" => 20_000,
               "advanceWeekday" => weekday,
               "advanceMode" => "automatic"
             })

    Application.put_env(:mithril, :resend_api_key, "re_test")
    Application.put_env(:mithril, :resend_req_options, plug: {Req.Test, Mithril.DirectContracts})

    Req.Test.stub(Mithril.DirectContracts, fn conn ->
      Req.Test.json(conn, %{"id" => "email_1"})
    end)

    assert {:ok,
            %{
              "invoiceNo" => invoice_no,
              "channel" => "email",
              "sent" => true,
              "totalMinor" => 400_000
            }} =
             DirectContracts.send_invoice(admin_id, contract_id, %{
               "month" => month,
               "style" => "per_worker",
               "channel" => "email"
             })

    assert invoice_no =~ "INV-"

    assert {:error, :invoice_already_sent} =
             DirectContracts.send_invoice(admin_id, contract_id, %{
               "month" => month,
               "style" => "one_line",
               "channel" => "email"
             })

    assert {:ok, detail} = DirectContracts.show(admin_id, contract_id, month)
    assert detail["advancesPaidMinor"] == 20_000
    assert detail["marginMinor"] == 400_000 - 250_000
    assert detail["paydayClosed"] == true
    assert detail["invoiceStatus"] == "sent_email"
    assert hd(detail["advances"])["reference"] =~ "WLT-"
    assert hd(detail["advances"])["paidByName"] == "Automatic · 06:00"
  end

  defp normalize_automatic(:ok), do: {:ok, %{"paidCount" => 0, "totalMinor" => 0}}
  defp normalize_automatic(other), do: other

  defp named_worker!(name) do
    id = Fixtures.insert_worker!()

    Repo.query!("INSERT INTO public.profiles (id, fullname) VALUES ($1, $2)", [
      Ecto.UUID.dump!(id),
      name
    ])

    id
  end

  defp install_contracts! do
    sql =
      File.read!(
        Path.expand("../../priv/repo/sql/direct/20261030120000_direct_contracts.sql", __DIR__)
      )

    [ddl, function] = String.split(sql, "-- FUNCTION\n", parts: 2)

    for statement <- String.split(ddl, ";\n"),
        statement = String.trim(statement),
        statement != "" do
      Repo.query!(statement)
    end

    Repo.query!(String.trim(function))
  end
end
