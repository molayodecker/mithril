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
    assert detail["letterPreview"]["clientName"] == "Kofi Mensah Holdings"
    assert length(detail["letterPreview"]["clauses"]) == 12
    ending = Enum.find(detail["letterPreview"]["clauses"], &(&1["title"] == "Ending"))

    after_end =
      Enum.find(detail["letterPreview"]["clauses"], &(&1["title"] == "After the letter ends"))

    assert ending["body"] =~ "2 months"
    assert after_end["body"] =~ "6 months"
  end

  test "a contract letter names the client, the workers, and the monthly fee" do
    admin_id = Fixtures.insert_user!("admin")
    stranger_id = Fixtures.insert_user!("reviewer")
    today = Date.utc_today()
    weekday = if Date.day_of_week(today) == 7, do: 0, else: Date.day_of_week(today)

    assert {:ok, %{"id" => empty_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Empty Household",
               "kind" => "person",
               "monthlyFeeMinor" => 100_000
             })

    assert {:error, :letter_needs_worker} =
             DirectContracts.send_letter(admin_id, empty_id, %{"channel" => "email"})

    worker_id = named_worker!("Ama Owusu")
    other_id = named_worker!("Abena Asante")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Kofi Mensah Holdings",
               "kind" => "company",
               "billingContact" => "Esi Mensah",
               "phone" => "+233245550142",
               "email" => "accounts@kmholdings.com.gh",
               "monthlyFeeMinor" => 400_000
             })

    assert {:error, :forbidden} =
             DirectContracts.send_letter(stranger_id, contract_id, %{"channel" => "email"})

    assert {:ok, %{"id" => househelp_assignment_id}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 120_000,
               "clientRateMinor" => 200_000,
               "weeklyAdvanceMinor" => 20_000,
               "advanceWeekday" => weekday,
               "advanceMode" => "manual"
             })

    assert {:ok, %{"id" => cook_assignment_id}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => other_id,
               "roleLabel" => "Cook",
               "monthlyPayMinor" => 130_000,
               "clientRateMinor" => 200_000,
               "advanceMode" => "manual"
             })

    Application.put_env(:mithril, :resend_api_key, "")

    assert {:error, :email_not_configured} =
             DirectContracts.send_letter(admin_id, contract_id, %{"channel" => "email"})

    assert {:ok, %{"letters" => []}} = DirectContracts.list_for_customer(worker_id)

    Application.put_env(:mithril, :resend_api_key, "re_test")
    Application.put_env(:mithril, :resend_req_options, plug: {Req.Test, Mithril.DirectContracts})

    Req.Test.stub(Mithril.DirectContracts, fn conn ->
      Req.Test.json(conn, %{"id" => "email_letter"})
    end)

    assert {:ok, %{"letterNo" => first_no, "sent" => true, "viewUrl" => view_url}} =
             DirectContracts.send_letter(admin_id, contract_id, %{"channel" => "email"})

    assert first_no =~ "LTR-"
    token = view_url |> String.split("/") |> List.last()
    assert {:ok, letter} = DirectContracts.public_letter(token)
    assert letter["clientName"] == "Kofi Mensah Holdings"
    assert letter["monthlyFeeMinor"] == 400_000

    assert Enum.sort_by(letter["workers"], & &1["workerName"]) == [
             %{"roleLabel" => "Cook", "workerName" => "Abena Asante"},
             %{"roleLabel" => "Househelp", "workerName" => "Ama Owusu"}
           ]

    encoded = Jason.encode!(letter)
    refute encoded =~ "120000"
    refute encoded =~ "monthlyPay"
    refute encoded =~ "weeklyAdvance"
    assert Enum.any?(letter["clauses"], &String.contains?(&1["body"], "GHS 4000.00"))

    assert {:ok, %{"letters" => [worker_letter]}} = DirectContracts.list_for_customer(worker_id)
    assert worker_letter["kind"] == "worker"
    assert worker_letter["workerName"] == "Ama Owusu"
    assert worker_letter["monthlyPayMinor"] == 120_000
    assert worker_letter["weeklyAdvanceMinor"] == 20_000
    assert worker_letter["active"] == true
    assert Enum.any?(worker_letter["clauses"], &String.contains?(&1["body"], "GHS 1200.00"))
    refute Enum.any?(worker_letter["clauses"], &String.contains?(&1["body"], "GHS 4000.00"))

    assert {:ok, %{"letterNo" => second_no}} =
             DirectContracts.send_letter(admin_id, contract_id, %{"channel" => "email"})

    assert second_no != first_no

    assert {:ok, detail} = DirectContracts.show(admin_id, contract_id, nil)
    assert Enum.map(detail["letters"], & &1["letterNo"]) == [second_no, first_no]
    assert hd(detail["letters"])["status"] == "sent_email"

    assert {:ok, _} =
             DirectContracts.end_assignment(admin_id, contract_id, househelp_assignment_id)

    assert {:ok, %{"letters" => ended_worker_letters}} =
             DirectContracts.list_for_customer(worker_id)

    assert ended_worker_letters != []
    assert Enum.all?(ended_worker_letters, &(&1["active"] == false))

    client_id = Fixtures.insert_user!()
    set_contact!(client_id, "+233245550142", nil)

    assert {:ok, %{"letters" => client_letters}} = DirectContracts.list_for_customer(client_id)
    assert client_letters != []
    assert Enum.all?(client_letters, &(&1["active"] == true))

    assert {:ok, _} = DirectContracts.end_assignment(admin_id, contract_id, cook_assignment_id)

    assert {:ok, %{"letters" => ended_client_letters}} =
             DirectContracts.list_for_customer(client_id)

    assert ended_client_letters != []
    assert Enum.all?(ended_client_letters, &(&1["active"] == false))
  end

  test "a contract contact must be a Ghana number and a real email" do
    admin_id = Fixtures.insert_user!("admin")

    assert {:error, :invalid_phone} =
             DirectContracts.create(admin_id, %{
               "name" => "Dede",
               "kind" => "company",
               "phone" => "+23350000000",
               "monthlyFeeMinor" => 300_000
             })

    assert {:error, :invalid_email} =
             DirectContracts.create(admin_id, %{
               "name" => "Dede",
               "kind" => "company",
               "email" => "not-an-email",
               "monthlyFeeMinor" => 300_000
             })

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Dede",
               "kind" => "company",
               "phone" => "024 000 0000",
               "email" => "accounts@example.com",
               "monthlyFeeMinor" => 300_000
             })

    [[phone, email]] =
      Repo.query!(
        """
        SELECT cl.phone, cl.email
        FROM public.direct_contract_clients cl
        JOIN public.direct_contracts c ON c.client_id = cl.id
        WHERE c.id = $1
        """,
        [Ecto.UUID.dump!(contract_id)]
      ).rows

    assert phone == "+233240000000"
    assert email == "accounts@example.com"
  end

  test "a signed-in client sees a sent letter that matches their account" do
    admin_id = Fixtures.insert_user!("admin")
    customer_id = Fixtures.insert_user!()
    stranger_id = Fixtures.insert_user!()
    set_contact!(customer_id, "+233244123456", "someone-else@example.com")
    set_contact!(stranger_id, "+233201112233", "stranger@example.com")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Dede",
               "kind" => "person",
               "phone" => "0244123456",
               "email" => "dede@example.com",
               "monthlyFeeMinor" => 300_000
             })

    insert_letter!(contract_id, admin_id, %{
      number: "LTR-2026-901",
      token: String.duplicate("ab", 32),
      phone: "+233244123456",
      email: "dede@example.com",
      sent: true
    })

    insert_letter!(contract_id, admin_id, %{
      number: "LTR-2026-902",
      token: String.duplicate("cd", 32),
      phone: "+233244123456",
      email: "dede@example.com",
      sent: false
    })

    assert {:ok, %{"letters" => [letter]}} = DirectContracts.list_for_customer(customer_id)
    assert letter["letterNo"] == "LTR-2026-901"
    assert letter["clientName"] == "Dede"
    refute Map.has_key?(letter, "publicToken")

    email_match_id = Fixtures.insert_user!()
    set_contact!(email_match_id, nil, "Dede@Example.com")

    assert {:ok, %{"letters" => [%{"letterNo" => "LTR-2026-901"}]}} =
             DirectContracts.list_for_customer(email_match_id)

    assert {:ok, %{"letters" => []}} = DirectContracts.list_for_customer(stranger_id)
  end

  defp set_contact!(user_id, phone, email) do
    Repo.query!("UPDATE public.users SET phone = $2, email = $3 WHERE id = $1", [
      Ecto.UUID.dump!(user_id),
      phone,
      email
    ])
  end

  defp insert_letter!(contract_id, admin_id, attrs) do
    Repo.query!(
      """
      INSERT INTO public.direct_contract_letters (
        contract_id, letter_no, public_token, issued_on, start_on, monthly_fee_minor,
        client_name, phone, email, preamble, workers, clauses, channel, sent_at, created_by
      ) VALUES (
        $1, $2, $3, CURRENT_DATE, CURRENT_DATE, 300000,
        'Dede', $4, $5, 'Agreement', $6::jsonb, $7::jsonb, 'email', $8, $9
      )
      """,
      [
        Ecto.UUID.dump!(contract_id),
        attrs.number,
        attrs.token,
        attrs.phone,
        attrs.email,
        [%{"roleLabel" => "Househelp", "workerName" => "Ama"}],
        [%{"number" => 7, "title" => "Ending", "body" => "2 months"}],
        if(attrs.sent, do: DateTime.utc_now(), else: nil),
        Ecto.UUID.dump!(admin_id)
      ]
    )
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
    install_sql!("../../priv/repo/sql/direct/20261101120000_direct_contract_letters.sql")
    install_sql!("../../priv/repo/sql/direct/20261101130000_direct_contract_worker_letters.sql")
  end

  defp install_sql!(relative) do
    sql = File.read!(Path.expand(relative, __DIR__))

    for statement <- String.split(sql, ";\n"),
        statement = String.trim(statement),
        statement != "" do
      Repo.query!(statement)
    end
  end
end
