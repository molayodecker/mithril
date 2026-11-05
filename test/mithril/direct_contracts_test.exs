defmodule Mithril.DirectContractsTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.DirectContracts
  alias Mithril.DirectContracts.Calendar
  alias Mithril.DirectContracts.Letter
  alias Mithril.Repo
  alias Mithril.WhatsApp.ContractLetterTemplate
  alias Mithril.WhatsApp.WorkerAddedTemplate

  setup do
    Fixtures.checkout!()
    install_contracts!()
    :ok
  end

  test "the service agreement can leave out invoices" do
    contract = %{
      created_at: ~U[2026-01-02 08:00:00Z],
      include_invoices: false,
      name: "Client",
      monthly_fee_minor: 400_000,
      currency: "GHS",
      billing_contact: nil,
      phone: nil,
      email: nil
    }

    preview = Letter.preview(contract, [])
    refute Enum.any?(preview["clauses"], &(&1["title"] == "Invoices"))
    assert length(preview["clauses"]) == 11

    whole = Enum.find(preview["clauses"], &(&1["title"] == "The whole agreement"))
    refute whole["body"] =~ "invoices issued"
  end

  test "the service agreement uses the chosen start date" do
    contract = %{
      created_at: ~U[2026-01-02 08:00:00Z],
      start_on: ~D[2026-03-15],
      name: "Client",
      monthly_fee_minor: 400_000,
      currency: "GHS",
      billing_contact: nil,
      phone: nil,
      email: nil
    }

    preview = Letter.preview(contract, [])
    assert preview["startOn"] == "2026-03-15"
    assert Enum.any?(preview["clauses"], &String.contains?(&1["body"], "15 Mar 2026"))
  end

  test "removing an earlier invoice does not reuse an existing invoice number" do
    admin_id = Fixtures.insert_user!("admin")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Numbered Invoice Client",
               "kind" => "person",
               "monthlyFeeMinor" => 100_000
             })

    for {month, number} <- [{~D[2026-01-01], "INV-2026-001"}, {~D[2026-02-01], "INV-2026-002"}] do
      Repo.query!(
        """
        INSERT INTO public.direct_contract_invoices
          (contract_id, period_month, invoice_no, public_token, issued_on, due_on, style, total_minor, created_by)
        VALUES ($1, $2, $3, $4, CURRENT_DATE, CURRENT_DATE, 'one_line', 100000, $5)
        """,
        [
          Ecto.UUID.dump!(contract_id),
          month,
          number,
          Ecto.UUID.generate(),
          Ecto.UUID.dump!(admin_id)
        ]
      )
    end

    # Simulate the migration initializing the counter from pre-existing invoices.
    Repo.query!("SELECT setval('public.direct_contract_invoice_no_seq', 2)")

    %{rows: [[old_id]]} =
      Repo.query!(
        "SELECT id::text FROM public.direct_contract_invoices WHERE invoice_no = 'INV-2026-001'"
      )

    assert {:ok, _} = DirectContracts.remove_invoice(admin_id, contract_id, old_id)

    # This exercises the allocator without depending on a configured outbound provider.
    assert {:error, :missing_email} =
             DirectContracts.send_invoice(admin_id, contract_id, %{
               "month" => "2026-01",
               "style" => "one_line",
               "channel" => "email"
             })

    %{rows: [[new_number]]} =
      Repo.query!(
        "SELECT invoice_no FROM public.direct_contract_invoices WHERE contract_id = $1 AND period_month = '2026-01-01'",
        [Ecto.UUID.dump!(contract_id)]
      )

    refute new_number in ["INV-2026-001", "INV-2026-002"]
  end

  test "an invoice cannot be removed while delivery is claimed" do
    admin_id = Fixtures.insert_user!("admin")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Delivery Client",
               "kind" => "person",
               "monthlyFeeMinor" => 100_000
             })

    invoice_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.direct_contract_invoices
        (id, contract_id, period_month, invoice_no, public_token, issued_on, due_on, style, total_minor, created_by, sending_at)
      VALUES ($1, $2, CURRENT_DATE, $3, $4, CURRENT_DATE, CURRENT_DATE, 'one_line', 100000, $5, now())
      """,
      [
        Ecto.UUID.dump!(invoice_id),
        Ecto.UUID.dump!(contract_id),
        "INV-CLAIM-#{invoice_id}",
        Ecto.UUID.generate(),
        Ecto.UUID.dump!(admin_id)
      ]
    )

    assert {:error, :invoice_delivery_in_progress} =
             DirectContracts.remove_invoice(admin_id, contract_id, invoice_id)

    assert Repo.query!("SELECT count(*) FROM public.direct_contract_invoices WHERE id = $1", [
             Ecto.UUID.dump!(invoice_id)
           ]).rows == [[1]]
  end

  test "the service agreement starts on the day the contract was created when no start date is set" do
    contract = %{
      created_at: ~U[2026-01-02 08:00:00Z],
      start_on: nil,
      name: "Client",
      monthly_fee_minor: 400_000,
      currency: "GHS",
      billing_contact: nil,
      phone: nil,
      email: nil
    }

    preview = Letter.preview(contract, [])
    assert preview["startOn"] == "2026-01-02"
    assert Enum.any?(preview["clauses"], &String.contains?(&1["body"], "2 Jan 2026"))
  end

  test "worker letter starts on assignment date, not original contract date" do
    contract = %{created_at: ~D[2026-01-01], name: "Client", currency: "GHS"}

    worker = %{
      started_at: ~D[2026-10-15],
      worker_name: "Ama Owusu",
      role_label: "Househelp",
      phone: nil,
      email: nil,
      monthly_pay_minor: 120_000,
      weekly_advance_minor: 0
    }

    letter = Letter.worker_letter(contract, worker)
    assert letter["startOn"] == "2026-10-15"
    assert Enum.any?(letter["clauses"], &String.contains?(&1["body"], "15 Oct 2026"))
  end

  test "the service agreement whatsapp template opens the client letter" do
    previous = Application.get_env(:mithril, :direct_public_url)
    Application.put_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:mithril, :direct_public_url)
      else
        Application.put_env(:mithril, :direct_public_url, previous)
      end
    end)

    definition = ContractLetterTemplate.definition()
    action = hd(definition["types"]["twilio/call-to-action"]["actions"])
    token = "a1b2c3d4e5f6789012345678abcdef0123456789abcdef0123456789abcdef01"
    url = "https://direct.tryinstaclean.com/letters/contract/#{token}"

    assert definition["friendly_name"] == "instaclean_service_agreement"

    assert String.ends_with?(
             definition["types"]["twilio/call-to-action"]["body"],
             "Tap below to view it."
           )

    assert action["title"] == "View agreement"
    assert action["url"] == "https://direct.tryinstaclean.com/{{4}}"
    assert ContractLetterTemplate.path(url) == "letters/contract/#{token}"

    assert ContractLetterTemplate.path("https://direct.tryinstaclean.com/letters/worker/#{token}") ==
             nil

    assert ContractLetterTemplate.variables(%{
             "customerName" => " Esi\nMensah ",
             "letterNo" => "LTR-2026-001",
             "amountLabel" => "GHS 4,000.00",
             "path" => "letters/contract/#{token}"
           }) == %{
             "1" => "Esi Mensah",
             "2" => "LTR-2026-001",
             "3" => "GHS 4,000.00",
             "4" => "letters/contract/#{token}"
           }

    assert ContractLetterTemplate.customer_name(%{
             "clientName" => "Ama Mensah",
             "billingContact" => "0243558645"
           }) == "Ama Mensah"
  end

  test "the worker added whatsapp template names the worker, role, and client" do
    definition = WorkerAddedTemplate.definition()

    assert definition["friendly_name"] == "instaclean_worker_added"
    assert definition["types"]["twilio/text"]["body"] == WorkerAddedTemplate.body()

    assert String.ends_with?(
             WorkerAddedTemplate.body(),
             "Open the Instaclean app to see your assignment."
           )

    assert WorkerAddedTemplate.variables(%{
             "workerName" => " Ama\nOwusu ",
             "roleLabel" => "Househelp",
             "clientName" => "Kofi Mensah Holdings"
           }) == %{
             "1" => "Ama Owusu",
             "2" => "Househelp",
             "3" => "Kofi Mensah Holdings"
           }
  end

  test "a weekly advance credits the wallet, payday pays the remainder, and the loan book stays empty" do
    admin_id = Fixtures.insert_user!("admin")
    stranger_id = Fixtures.insert_user!()
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

  test "contract reviewers can pay advances without gaining unrelated wallet credit rights" do
    admin_id = Fixtures.insert_user!("admin")
    reviewer_id = Fixtures.insert_user!("reviewer")
    restricted_id = Fixtures.insert_user!("reviewer")
    legacy_id = Fixtures.insert_user!("reviewer")
    worker_id = named_worker!("Contract worker")
    today = Date.utc_today()
    weekday = rem(Date.day_of_week(today), 7)

    for {id, desk} <- [{reviewer_id, "contracts"}, {restricted_id, "billing"}] do
      Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, $2)", [
        Ecto.UUID.dump!(id),
        desk
      ])
    end

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Reviewer payouts client",
               "kind" => "company",
               "monthlyFeeMinor" => 100_000
             })

    assert {:ok, %{"id" => assignment_id}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Housekeeper",
               "monthlyPayMinor" => 50_000,
               "clientRateMinor" => 60_000,
               "weeklyAdvanceMinor" => 10_000,
               "advanceWeekday" => weekday,
               "advanceMode" => "manual"
             })

    assert {:error, :forbidden} = DirectContracts.show(restricted_id, contract_id, nil)
    assert {:ok, _} = DirectContracts.show(reviewer_id, contract_id, nil)
    assert {:ok, _} = DirectContracts.show(legacy_id, contract_id, nil)

    assert {:error, :forbidden} =
             DirectContracts.pay_advance(restricted_id, contract_id, %{
               "assignmentId" => assignment_id,
               "weekOn" => Date.to_iso8601(today)
             })

    assert {:ok, _} =
             DirectContracts.pay_advance(reviewer_id, contract_id, %{
               "assignmentId" => assignment_id,
               "weekOn" => Date.to_iso8601(today)
             })

    assert Repo.query!(
             "SELECT count(*) FROM public.admin_wallet_credits WHERE recorded_by = $1",
             [
               Ecto.UUID.dump!(reviewer_id)
             ]
           ).rows == [[1]]

    assert Repo.query!("SELECT public.admin_cash_payout_recorder_is_allowed($1::uuid)", [
             Ecto.UUID.dump!(reviewer_id)
           ]).rows == [[false]]
  end

  @signature "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  test "Instaclean and the client can sign the service agreement" do
    admin_id = Fixtures.insert_user!("admin")
    stranger_id = Fixtures.insert_user!()
    worker_id = named_worker!("Ama Owusu")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Signed Household",
               "kind" => "person",
               "phone" => "+233245550142",
               "email" => "signed@example.com",
               "monthlyFeeMinor" => 200_000
             })

    assert {:error, :invalid_request} =
             DirectContracts.sign_provider(admin_id, contract_id, %{
               "signerName" => "Abena Quaye",
               "signature" => "not-a-signature"
             })

    assert {:error, :forbidden} =
             DirectContracts.sign_provider(stranger_id, contract_id, %{
               "signerName" => "Abena Quaye",
               "signature" => @signature
             })

    assert {:ok, _} =
             DirectContracts.sign_provider(admin_id, contract_id, %{
               "signerName" => "Abena Quaye",
               "signature" => @signature
             })

    assert {:error, :letter_already_signed} =
             DirectContracts.sign_provider(admin_id, contract_id, %{
               "signerName" => "Someone Else",
               "signature" => @signature
             })

    assert {:ok, detail} = DirectContracts.show(admin_id, contract_id, nil)
    assert detail["letterPreview"]["providerSignature"]["signerName"] == "Abena Quaye"
    assert detail["letterPreview"]["providerSignature"]["signature"] == @signature
    assert detail["letterPreview"]["counterpartySignature"] == nil

    assert {:ok, _} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 80_000,
               "clientRateMinor" => 200_000,
               "advanceMode" => "manual"
             })

    Application.put_env(:mithril, :resend_api_key, "re_test")
    Application.put_env(:mithril, :resend_req_options, plug: {Req.Test, Mithril.DirectContracts})

    Req.Test.stub(Mithril.DirectContracts, fn conn ->
      Req.Test.json(conn, %{"id" => "email_signed_letter"})
    end)

    assert {:ok, %{"viewUrl" => view_url}} =
             DirectContracts.send_letter(admin_id, contract_id, %{"channel" => "email"})

    token = view_url |> String.split("/") |> List.last()
    assert {:ok, letter} = DirectContracts.public_letter(token)
    assert letter["providerSignature"]["signerName"] == "Abena Quaye"
    assert letter["counterpartySignature"] == nil

    assert {:ok, signed} =
             DirectContracts.sign_public_letter(token, %{
               "signerName" => "Signed Household",
               "signature" => @signature
             })

    assert signed["counterpartySignature"]["signerName"] == "Signed Household"

    assert {:ok, signed_detail} = DirectContracts.show(admin_id, contract_id, nil)

    assert signed_detail["letterPreview"]["counterpartySignature"]["signerName"] ==
             "Signed Household"

    assert hd(signed_detail["letters"])["clientSigned"] == true
    assert hd(signed_detail["letters"])["clientSignerName"] == "Signed Household"

    # Editing live terms must not imply that the client signed the new terms.
    assert {:ok, _} =
             DirectContracts.update_client(admin_id, contract_id, %{
               "name" => "Signed Household",
               "kind" => "person",
               "phone" => "+233245550142",
               "email" => "signed@example.com",
               "monthlyFeeMinor" => 250_000
             })

    assert {:ok, edited_detail} = DirectContracts.show(admin_id, contract_id, nil)
    assert edited_detail["letterPreview"]["monthlyFeeMinor"] == 250_000
    assert edited_detail["letterPreview"]["counterpartySignature"] == nil
    assert hd(edited_detail["letters"])["clientSigned"] == true

    # A subsequent unsigned snapshot supersedes the earlier signed letter.
    assert {:ok, _} = DirectContracts.save_letter(admin_id, contract_id)
    assert {:ok, newer_detail} = DirectContracts.show(admin_id, contract_id, nil)
    assert newer_detail["letterPreview"]["counterpartySignature"] == nil
    assert hd(newer_detail["letters"])["clientSigned"] == false

    # Lexicographic ordering puts 999 after 1000; creation order must win.
    Repo.query!(
      """
      UPDATE public.direct_contract_letters
      SET letter_no = CASE WHEN client_signed_at IS NULL
                           THEN 'LTR-2099-1000' ELSE 'LTR-2099-999' END
      WHERE contract_id = $1
      """,
      [Ecto.UUID.dump!(contract_id)]
    )

    assert {:ok, numbered_detail} = DirectContracts.show(admin_id, contract_id, nil)
    assert hd(numbered_detail["letters"])["letterNo"] == "LTR-2099-1000"
    assert numbered_detail["letterPreview"]["counterpartySignature"] == nil

    assert {:error, :letter_already_signed} =
             DirectContracts.sign_public_letter(token, %{
               "signerName" => "Signed Household",
               "signature" => @signature
             })

    [[worker_token]] =
      Repo.query!(
        """
        SELECT public_token FROM public.direct_contract_worker_letters
        WHERE contract_id = $1 AND sent_at IS NOT NULL
        ORDER BY created_at, id
        LIMIT 1
        """,
        [Ecto.UUID.dump!(contract_id)]
      ).rows

    assert {:ok, worker_letter} = DirectContracts.public_worker_letter(worker_token)
    assert worker_letter["providerSignature"]["signerName"] == "Abena Quaye"

    assert {:ok, signed_worker} =
             DirectContracts.sign_public_worker_letter(worker_token, %{
               "signerName" => "Ama Owusu",
               "signature" => @signature
             })

    assert signed_worker["counterpartySignature"]["signerName"] == "Ama Owusu"
  end

  test "a contract letter names the client, the workers, and the monthly fee" do
    admin_id = Fixtures.insert_user!("admin")
    stranger_id = Fixtures.insert_user!()
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

    assert {:ok, %{"letters" => []}} = DirectContracts.list_for_customer(client_id)
    assert {:ok, %{"active" => true}} = DirectContracts.public_letter(token)

    assert {:ok, _} = DirectContracts.end_assignment(admin_id, contract_id, cook_assignment_id)

    assert {:ok, %{"letters" => []}} = DirectContracts.list_for_customer(client_id)
    assert {:ok, %{"active" => false}} = DirectContracts.public_letter(token)
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

  test "unverified contact matches cannot expose client agreements" do
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

    assert {:ok, %{"letters" => []}} = DirectContracts.list_for_customer(customer_id)

    email_match_id = Fixtures.insert_user!()
    set_contact!(email_match_id, nil, "Dede@Example.com")

    assert {:ok, %{"letters" => []}} = DirectContracts.list_for_customer(email_match_id)

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

  test "a phone number creates a worker who is not on the roster" do
    admin_id = Fixtures.insert_user!("admin")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Kofi Mensah Holdings",
               "kind" => "company",
               "monthlyFeeMinor" => 400_000
             })

    assert DirectContracts.worker_added_message("Ama\nOwusu", "Househelp", "Kofi Mensah Holdings") ==
             "Hello Ama Owusu, Instaclean has added you as Househelp for Kofi Mensah Holdings. Open the Instaclean app to see your assignment."

    assert {:ok, %{"id" => assignment_id, "notified" => false}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerPhone" => "0245550142",
               "workerName" => "Ama Owusu",
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 120_000,
               "clientRateMinor" => 200_000
             })

    [[worker_id, phone, name]] =
      Repo.query!(
        """
        SELECT a.worker_id::text, u.phone, p.fullname
        FROM public.direct_contract_assignments a
        JOIN public.users u ON u.id = a.worker_id
        JOIN public.profiles p ON p.id = a.worker_id
        JOIN public.cleaner_data cd ON cd.user_id = a.worker_id
        WHERE a.id = $1::uuid
        """,
        [Ecto.UUID.dump!(assignment_id)]
      ).rows

    assert phone == "+233245550142"
    assert name == "Ama Owusu"

    assert {:error, :worker_already_assigned} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerPhone" => "+233245550142",
               "workerName" => "Someone Else",
               "roleLabel" => "Cook",
               "monthlyPayMinor" => 100_000,
               "clientRateMinor" => 100_000
             })

    assert {:ok, %{"id" => second_contract}} =
             DirectContracts.create(admin_id, %{
               "name" => "Second Client",
               "kind" => "person",
               "monthlyFeeMinor" => 100_000
             })

    assert {:ok, %{"notified" => false}} =
             DirectContracts.add_assignment(admin_id, second_contract, %{
               "workerPhone" => "+233245550142",
               "workerName" => "Someone Else",
               "roleLabel" => "Cook",
               "monthlyPayMinor" => 100_000,
               "clientRateMinor" => 100_000
             })

    assert Repo.query!("SELECT count(*) FROM public.users WHERE phone = '+233245550142'").rows ==
             [[1]]

    assert Repo.query!("SELECT fullname FROM public.profiles WHERE id = $1", [
             Ecto.UUID.dump!(worker_id)
           ]).rows == [["Ama Owusu"]]

    assert {:error, :invalid_phone} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerPhone" => "not-a-phone",
               "workerName" => "Ama Owusu",
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 120_000,
               "clientRateMinor" => 200_000
             })

    assert {:error, :invalid_request} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerPhone" => "+233245550142",
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 120_000,
               "clientRateMinor" => 200_000
             })
  end

  test "a local-format customer phone reuses the account and grants cleaner payouts" do
    admin_id = Fixtures.insert_user!("admin")
    customer_id = Fixtures.insert_user!()
    Repo.query!("CREATE TABLE IF NOT EXISTS public.roles (id text PRIMARY KEY)")

    Repo.query!("UPDATE public.users SET phone = $2 WHERE id = $1", [
      Ecto.UUID.dump!(customer_id),
      "0245550142"
    ])

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Customer reuse client",
               "kind" => "company",
               "monthlyFeeMinor" => 100_000
             })

    assert {:ok, %{"id" => assignment_id, "notified" => false}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerPhone" => "+233245550142",
               "workerName" => "Existing Customer",
               "roleLabel" => "Housekeeper",
               "monthlyPayMinor" => 50_000,
               "clientRateMinor" => 60_000
             })

    assert Repo.query!(
             "SELECT worker_id FROM public.direct_contract_assignments WHERE id = $1",
             [Ecto.UUID.dump!(assignment_id)]
           ).rows == [[Ecto.UUID.dump!(customer_id)]]

    assert Repo.query!(
             "SELECT role_id FROM public.user_roles WHERE user_id = $1 AND role_id = 'cleaner'",
             [Ecto.UUID.dump!(customer_id)]
           ).rows == [["cleaner"]]

    assert Repo.query!("SELECT count(*) FROM public.users").rows == [[2]]
  end

  test "a mistaken assignment can be removed until a payment exists" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = named_worker!("Emilia Agyei")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Maame Dede Buckman",
               "kind" => "person",
               "monthlyFeeMinor" => 350_000
             })

    assert {:ok, %{"id" => assignment_id}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 160_000,
               "clientRateMinor" => 160_000
             })

    assert {:ok, _} = DirectContracts.end_assignment(admin_id, contract_id, assignment_id)

    assert {:ok, stuck} = DirectContracts.show(admin_id, contract_id, nil)
    assert Enum.map(stuck["workers"], & &1["workerName"]) == ["Emilia Agyei"]
    assert stuck["netDueMinor"] == 160_000

    assert {:ok, %{"id" => ^assignment_id}} =
             DirectContracts.remove_assignment(admin_id, contract_id, assignment_id)

    assert {:ok, cleared} = DirectContracts.show(admin_id, contract_id, nil)
    assert cleared["workers"] == []
    assert cleared["netDueMinor"] == 0

    assert {:ok, %{"id" => again_id}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 160_000,
               "clientRateMinor" => 160_000
             })

    %{rows: [[payday_id]]} =
      Repo.query!(
        """
        INSERT INTO public.direct_contract_paydays (contract_id, period_month, paid_by, total_net_minor)
        VALUES ($1, date_trunc('month', CURRENT_DATE)::date, $2, 0)
        RETURNING id
        """,
        [Ecto.UUID.dump!(contract_id), Ecto.UUID.dump!(admin_id)]
      )

    Repo.query!(
      """
      INSERT INTO public.direct_contract_payday_lines (
        payday_id, assignment_id, gross_minor, advances_minor, net_minor
      ) VALUES ($1, $2, 0, 0, 0)
      """,
      [payday_id, Ecto.UUID.dump!(again_id)]
    )

    assert {:error, :assignment_has_payments} =
             DirectContracts.remove_assignment(admin_id, contract_id, again_id)
  end

  test "a draft invoice line prevents removal with an actionable conflict" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = named_worker!("Draft Invoice Worker")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Draft Invoice Client",
               "kind" => "person",
               "monthlyFeeMinor" => 100_000
             })

    assert {:ok, %{"id" => assignment_id}} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 50_000,
               "clientRateMinor" => 50_000
             })

    invoice_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.direct_contract_invoices
        (id, contract_id, period_month, invoice_no, public_token, issued_on,
         due_on, style, total_minor, created_by)
      VALUES ($1, $2, CURRENT_DATE, $3, $4, CURRENT_DATE, CURRENT_DATE,
              'per_worker', 50000, $5)
      """,
      [
        Ecto.UUID.dump!(invoice_id),
        Ecto.UUID.dump!(contract_id),
        "INV-DRAFT-#{invoice_id}",
        "token-#{invoice_id}",
        Ecto.UUID.dump!(admin_id)
      ]
    )

    Repo.query!(
      """
      INSERT INTO public.direct_contract_invoice_lines
        (invoice_id, position, description, amount_minor, assignment_id)
      VALUES ($1, 0, 'Draft worker line', 50000, $2)
      """,
      [Ecto.UUID.dump!(invoice_id), Ecto.UUID.dump!(assignment_id)]
    )

    assert {:error, :assignment_has_invoice} =
             DirectContracts.remove_assignment(admin_id, contract_id, assignment_id)

    assert Repo.query!(
             "SELECT count(*) FROM public.direct_contract_assignments WHERE id = $1",
             [Ecto.UUID.dump!(assignment_id)]
           ).rows == [[1]]

    assert {:ok, %{"id" => other_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Other Invoice Client",
               "kind" => "person",
               "monthlyFeeMinor" => 100_000
             })

    assert {:error, :contract_invoice_not_found} =
             DirectContracts.remove_invoice(admin_id, other_id, invoice_id)

    assert {:ok, %{"id" => ^invoice_id}} =
             DirectContracts.remove_invoice(admin_id, contract_id, invoice_id)

    assert Repo.query!(
             "SELECT count(*) FROM public.direct_contract_invoices WHERE id = $1",
             [Ecto.UUID.dump!(invoice_id)]
           ).rows == [[0]]

    assert Repo.query!(
             "SELECT count(*) FROM public.direct_contract_invoice_lines WHERE invoice_id = $1",
             [Ecto.UUID.dump!(invoice_id)]
           ).rows == [[0]]

    assert {:error, :contract_invoice_not_found} =
             DirectContracts.remove_invoice(admin_id, contract_id, invoice_id)

    assert {:ok, %{"id" => ^assignment_id}} =
             DirectContracts.remove_assignment(admin_id, contract_id, assignment_id)
  end

  test "saving a contract letter assigns a number without sending it" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = named_worker!("Ama Owusu")

    assert {:ok, %{"id" => contract_id}} =
             DirectContracts.create(admin_id, %{
               "name" => "Saved Household",
               "kind" => "person",
               "monthlyFeeMinor" => 100_000
             })

    assert {:error, :letter_needs_worker} = DirectContracts.save_letter(admin_id, contract_id)

    assert {:ok, _} =
             DirectContracts.add_assignment(admin_id, contract_id, %{
               "workerId" => worker_id,
               "roleLabel" => "Househelp",
               "monthlyPayMinor" => 80_000,
               "clientRateMinor" => 100_000,
               "advanceMode" => "manual"
             })

    assert {:ok,
            %{"letterNo" => number, "sent" => false, "channel" => nil, "viewUrl" => view_url}} =
             DirectContracts.save_letter(admin_id, contract_id)

    assert number =~ "LTR-"
    token = view_url |> String.split("/") |> List.last()
    assert {:ok, letter} = DirectContracts.public_letter(token)
    assert letter["letterNo"] == number
    assert letter["clientName"] == "Saved Household"

    assert {:ok, detail} = DirectContracts.show(admin_id, contract_id, nil)
    assert hd(detail["letters"])["letterNo"] == number
    assert hd(detail["letters"])["status"] == "saved"
    assert {:ok, %{"letters" => []}} = DirectContracts.list_for_customer(worker_id)

    assert {:ok, %{"letterNo" => ^number, "sent" => false}} =
             DirectContracts.save_letter(admin_id, contract_id)
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
    install_sql!("../../priv/repo/sql/direct/20261101140000_direct_contract_letter_numbers.sql")
    install_sql!("../../priv/repo/sql/direct/20261101150000_direct_contract_letter_sending.sql")
    install_sql!("../../priv/repo/sql/direct/20261103150000_direct_contract_start_on.sql")
    install_sql!("../../priv/repo/sql/direct/20261103170000_direct_contract_include_invoices.sql")
    install_sql!("../../priv/repo/sql/direct/20261103180000_direct_contract_signatures.sql")
    install_sql!("../../priv/repo/sql/direct/20261103160000_direct_contract_invoice_delivery.sql")
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
