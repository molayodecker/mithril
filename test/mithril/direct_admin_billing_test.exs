defmodule Mithril.DirectAdminBillingTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Mithril.DirectAdminBilling
  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.Repo
  alias MithrilWeb.DirectAdminBillingController

  setup do
    Fixtures.checkout!()
    :ok
  end

  test "saves a custom invoice as 1099 and computes pesewas" do
    admin_id = Fixtures.insert_user!("admin")
    invoice_id = Ecto.UUID.generate()

    assert {:ok, saved} =
             DirectAdminBilling.upsert_invoice(admin_id, invoice_id, sample_invoice("1099"))

    assert saved["id"] == invoice_id
    assert saved["formType"] == "1099"
    assert saved["invoiceNo"] == "OLD-12"
    assert saved["subtotalMinor"] == 495_000
    assert saved["totalMinor"] == 480_000
    assert hd(saved["lines"])["totalMinor"] == 300_000

    assert {:ok, [listed]} = DirectAdminBilling.list_invoices(admin_id)
    assert listed["id"] == invoice_id
    assert listed["formType"] == "1099"

    assert {:ok, updated} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               sample_invoice("w8ben")
             )

    assert updated["id"] == invoice_id
    assert updated["formType"] == "w8ben"
  end

  test "a custom invoice requires a tax form and an admin" do
    admin_id = Fixtures.insert_user!("admin")
    stranger_id = Fixtures.insert_user!()
    invoice_id = Ecto.UUID.generate()

    assert {:error, :invalid_form_type} =
             DirectAdminBilling.upsert_invoice(admin_id, invoice_id, sample_invoice("w2"))

    assert {:error, :forbidden} =
             DirectAdminBilling.upsert_invoice(stranger_id, invoice_id, sample_invoice("w8ben"))

    assert {:error, :forbidden} = DirectAdminBilling.list_invoices(stranger_id)
  end

  test "invoice totals cannot become negative and archive pages are accessible" do
    admin_id = Fixtures.insert_user!("admin")

    assert {:error, :invalid_invoice} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               Ecto.UUID.generate(),
               Map.put(sample_invoice("1099"), "adjustmentMinor", -500_000)
             )

    assert {:error, :invalid_request} = DirectAdminBilling.list_invoices(admin_id, "abc")
    assert {:error, :invalid_request} = DirectAdminBilling.list_advices(admin_id, "0")
    assert {:ok, []} = DirectAdminBilling.list_invoices(admin_id, 2)
    assert {:ok, []} = DirectAdminBilling.list_advices(admin_id, 2)
  end

  test "payment advice net is earnings minus deductions plus reimbursements" do
    admin_id = Fixtures.insert_user!("admin")
    advice_id = Ecto.UUID.generate()

    assert {:ok, saved} =
             DirectAdminBilling.upsert_advice(admin_id, advice_id, sample_advice("w8ben"))

    assert saved["formType"] == "w8ben"
    assert saved["earningsMinor"] == 768_748
    assert saved["deductionsMinor"] == 183_748
    assert saved["reimbursementsMinor"] == 55_600
    assert saved["netMinor"] == 640_600
    assert saved["adviceNo"] == "PAY-2026-0231"

    assert {:ok, [listed]} = DirectAdminBilling.list_advices(admin_id)
    assert listed["id"] == advice_id
    assert listed["netMinor"] == 640_600
  end

  test "payment advice rejects a missing tax form" do
    admin_id = Fixtures.insert_user!("admin")

    assert {:error, :invalid_form_type} =
             DirectAdminBilling.upsert_advice(
               admin_id,
               Ecto.UUID.generate(),
               Map.delete(sample_advice("1099"), "formType")
             )
  end

  test "a blank invoice number is assigned and kept, and email is stored lowercase" do
    admin_id = Fixtures.insert_user!("admin")
    invoice_id = Ecto.UUID.generate()

    payload =
      sample_invoice("w8ben")
      |> Map.put("invoiceNo", "  ")
      |> Map.put("billToEmail", "Lucy@Example.com")

    assert {:ok, saved} = DirectAdminBilling.upsert_invoice(admin_id, invoice_id, payload)
    assert saved["invoiceNo"] =~ ~r/^\d+$/
    assert saved["billToEmail"] == "lucy@example.com"
    assert saved["lines"] |> Enum.map(& &1["totalMinor"]) == [300_000, 110_000, 55_000, 30_000]

    assert {:ok, again} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.put(payload, "invoiceNo", nil)
             )

    assert again["id"] == invoice_id
    assert again["invoiceNo"] == saved["invoiceNo"]
  end

  test "a blank payment advice number is assigned and blank money lines are dropped" do
    admin_id = Fixtures.insert_user!("admin")
    advice_id = Ecto.UUID.generate()

    payload =
      sample_advice("1099")
      |> Map.delete("adviceNo")
      |> Map.put("reimbursements", [])
      |> Map.put("deductions", [
        %{"description" => "PAYE", "amountMinor" => 141_467},
        %{"description" => "", "amountMinor" => nil}
      ])
      |> Map.put("paidToEmail", "Deborah.Omari@Gmail.com")

    assert {:ok, saved} = DirectAdminBilling.upsert_advice(admin_id, advice_id, payload)
    assert saved["adviceNo"] =~ ~r/^PAY-\d+$/
    assert saved["paidToEmail"] == "deborah.omari@gmail.com"
    assert saved["reimbursements"] == []
    assert length(saved["deductions"]) == 1
    assert saved["netMinor"] == 768_748 - 141_467

    assert {:ok, again} =
             DirectAdminBilling.upsert_advice(
               admin_id,
               advice_id,
               Map.put(payload, "adviceNo", "")
             )

    assert again["adviceNo"] == saved["adviceNo"]
  end

  test "invoices and advice are listed newest first" do
    admin_id = Fixtures.insert_user!("admin")
    older_id = Ecto.UUID.generate()
    newer_id = Ecto.UUID.generate()

    assert {:ok, _} =
             DirectAdminBilling.upsert_invoice(admin_id, older_id, sample_invoice("1099"))

    assert {:ok, _} =
             DirectAdminBilling.upsert_invoice(admin_id, newer_id, sample_invoice("w8ben"))

    touch!(older_id, "admin_billing_invoices")

    assert {:ok, [first, second]} = DirectAdminBilling.list_invoices(admin_id)
    assert first["id"] == older_id
    assert second["id"] == newer_id

    first_advice = Ecto.UUID.generate()
    second_advice = Ecto.UUID.generate()

    assert {:ok, _} =
             DirectAdminBilling.upsert_advice(admin_id, first_advice, sample_advice("w8ben"))

    assert {:ok, _} =
             DirectAdminBilling.upsert_advice(admin_id, second_advice, sample_advice("1099"))

    touch!(second_advice, "admin_payment_advices")
    assert {:ok, [listed, _other]} = DirectAdminBilling.list_advices(admin_id)
    assert listed["id"] == second_advice
  end

  test "rejects incomplete invoices, bad email, and totals that overflow pesewas" do
    admin_id = Fixtures.insert_user!("admin")
    invoice_id = Ecto.UUID.generate()

    assert {:error, :invalid_lines} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.update!(sample_invoice("1099"), "lines", fn [first | rest] ->
                 [Map.put(first, "days", nil) | rest]
               end)
             )

    assert {:error, :invalid_lines} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.put(sample_invoice("1099"), "lines", [])
             )

    assert {:error, :invalid_email} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.put(sample_invoice("1099"), "billToEmail", "lucy")
             )

    assert {:error, :invalid_invoice} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.put(sample_invoice("1099"), "issuedOn", "yesterday")
             )

    assert {:error, :invalid_invoice} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.put(sample_invoice("1099"), "billToName", "  ")
             )

    huge_line = %{"description" => "Work", "qty" => 10_000, "days" => 10_000, "unitMinor" => 2}

    assert {:error, :amount_too_large} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.put(sample_invoice("1099"), "lines", List.duplicate(huge_line, 20))
             )

    assert {:error, :invalid_request} =
             DirectAdminBilling.upsert_invoice(admin_id, "not-a-uuid", sample_invoice("1099"))

    assert {:error, :invalid_request} = DirectAdminBilling.list_invoices(nil)
  end

  test "rejects incomplete payment advice and a net that overflows" do
    admin_id = Fixtures.insert_user!("admin")
    advice_id = Ecto.UUID.generate()

    assert {:error, :invalid_lines} =
             DirectAdminBilling.upsert_advice(
               admin_id,
               advice_id,
               Map.put(sample_advice("1099"), "earnings", [])
             )

    assert {:error, :invalid_email} =
             DirectAdminBilling.upsert_advice(
               admin_id,
               advice_id,
               Map.put(sample_advice("1099"), "paidToEmail", "not-an-email")
             )

    assert {:error, :invalid_invoice} =
             DirectAdminBilling.upsert_advice(
               admin_id,
               advice_id,
               Map.put(sample_advice("1099"), "payPeriod", "")
             )

    assert {:error, :forbidden} =
             DirectAdminBilling.upsert_advice(
               Fixtures.insert_user!("reviewer"),
               advice_id,
               sample_advice("w8ben")
             )

    overflowing =
      sample_advice("1099")
      |> Map.put("earnings", [%{"description" => "Pay", "amountMinor" => 2_147_483_647}])
      |> Map.put("reimbursements", [%{"description" => "Extra", "amountMinor" => 1}])
      |> Map.put("deductions", [])

    assert {:error, :amount_too_large} =
             DirectAdminBilling.upsert_advice(admin_id, advice_id, overflowing)

    assert {:error, :invalid_request} = DirectAdminBilling.list_advices("not-a-uuid")
  end

  test "a caller-supplied admin id cannot write a billing document" do
    admin_id = Fixtures.insert_user!("admin")
    admin_uid = Ecto.UUID.dump!(admin_id)
    invoice_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    advice_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    other_actor = Ecto.UUID.generate()

    assert {:error, %Postgrex.Error{postgres: %{message: unbound_invoice}}} =
             Repo.query(
               "SELECT public.upsert_admin_billing_invoice($1::uuid, $2::uuid, '{}'::jsonb)",
               [invoice_id, admin_uid]
             )

    assert unbound_invoice =~ "recorded_by_not_authorized"

    assert {:error, %Postgrex.Error{postgres: %{message: unbound_advice}}} =
             Repo.query(
               "SELECT public.upsert_admin_payment_advice($1::uuid, $2::uuid, '{}'::jsonb)",
               [advice_id, admin_uid]
             )

    assert unbound_advice =~ "recorded_by_not_authorized"

    assert {:error, %Postgrex.Error{postgres: %{message: mismatched}}} =
             Repo.transaction(fn ->
               Repo.query!("SELECT set_config('mithril.actor_id', $1, true)", [other_actor])

               case Repo.query(
                      "SELECT public.upsert_admin_billing_invoice($1::uuid, $2::uuid, '{}'::jsonb)",
                      [invoice_id, admin_uid]
                    ) do
                 {:error, error} -> Repo.rollback(error)
               end
             end)

    assert mismatched =~ "recorded_by_not_authorized"
  end

  test "a reviewer can list billing documents but cannot save them" do
    reviewer_id = Fixtures.insert_user!("reviewer")

    assert {:ok, []} = DirectAdminBilling.list_invoices(reviewer_id)
    assert {:ok, []} = DirectAdminBilling.list_advices(reviewer_id)

    assert {:error, :forbidden} =
             DirectAdminBilling.upsert_invoice(
               reviewer_id,
               Ecto.UUID.generate(),
               sample_invoice("w8ben")
             )
  end

  test "http responses save, list, and reject billing documents" do
    admin_id = Fixtures.insert_user!("admin")
    stranger_id = Fixtures.insert_user!()
    invoice_id = Ecto.UUID.generate()
    advice_id = Ecto.UUID.generate()

    saved =
      DirectAdminBillingController.upsert_invoice(
        staff_conn(admin_id),
        Map.put(sample_invoice("1099"), "id", invoice_id)
      )

    assert json_response(saved, 200)["id"] == invoice_id

    listed = DirectAdminBillingController.index_invoices(staff_conn(admin_id), %{})
    assert [invoice] = json_response(listed, 200)["invoices"]
    assert invoice["formType"] == "1099"

    missing_form =
      DirectAdminBillingController.upsert_invoice(
        staff_conn(admin_id),
        Map.merge(sample_invoice("1099"), %{"id" => invoice_id, "formType" => "w2"})
      )

    assert json_response(missing_form, 422) == %{"error" => "invalid_form_type"}

    forbidden =
      DirectAdminBillingController.upsert_advice(
        staff_conn(stranger_id),
        Map.put(sample_advice("w8ben"), "id", advice_id)
      )

    assert json_response(forbidden, 403) == %{"error" => "forbidden"}

    advice =
      DirectAdminBillingController.upsert_advice(
        staff_conn(admin_id),
        Map.put(sample_advice("w8ben"), "id", advice_id)
      )

    assert json_response(advice, 200)["netMinor"] == 640_600

    advices = DirectAdminBillingController.index_advices(staff_conn(admin_id), %{})
    assert [row] = json_response(advices, 200)["advices"]
    assert row["id"] == advice_id

    unsigned =
      DirectAdminBillingController.upsert_invoice(
        build_conn(),
        Map.put(sample_invoice("1099"), "id", invoice_id)
      )

    assert json_response(unsigned, 422) == %{"error" => "invalid_request"}

    bad_lines =
      DirectAdminBillingController.upsert_invoice(
        staff_conn(admin_id),
        Map.merge(sample_invoice("1099"), %{"id" => Ecto.UUID.generate(), "lines" => []})
      )

    assert json_response(bad_lines, 422) == %{"error" => "invalid_lines"}

    bad_email =
      DirectAdminBillingController.upsert_advice(
        staff_conn(admin_id),
        Map.merge(sample_advice("1099"), %{
          "id" => Ecto.UUID.generate(),
          "paidToEmail" => "not-an-email"
        })
      )

    assert json_response(bad_email, 422) == %{"error" => "invalid_email"}

    bad_invoice =
      DirectAdminBillingController.upsert_invoice(
        staff_conn(admin_id),
        Map.merge(sample_invoice("1099"), %{
          "id" => Ecto.UUID.generate(),
          "issuedOn" => "yesterday"
        })
      )

    assert json_response(bad_invoice, 422) == %{"error" => "invalid_invoice"}

    huge_line = %{"description" => "Work", "qty" => 10_000, "days" => 10_000, "unitMinor" => 2}

    too_large =
      DirectAdminBillingController.upsert_invoice(
        staff_conn(admin_id),
        Map.merge(sample_invoice("1099"), %{
          "id" => Ecto.UUID.generate(),
          "lines" => List.duplicate(huge_line, 20)
        })
      )

    assert json_response(too_large, 422) == %{"error" => "amount_too_large"}
  end

  test "a missing database function is reported as unavailable" do
    admin_id = Fixtures.insert_user!("admin")

    Repo.query!("DROP FUNCTION public.upsert_admin_billing_invoice(uuid, uuid, jsonb)")

    assert {:error, :database_unavailable} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               Ecto.UUID.generate(),
               sample_invoice("1099")
             )

    conn =
      DirectAdminBillingController.upsert_invoice(
        staff_conn(admin_id),
        Map.put(sample_invoice("1099"), "id", Ecto.UUID.generate())
      )

    assert json_response(conn, 503) == %{"error" => "database_unavailable"}
  end

  defp staff_conn(user_id) do
    Plug.Conn.assign(build_conn(), :instaclean_user_id, user_id)
  end

  defp touch!(id, table) do
    Repo.query!(
      "UPDATE public.#{table} SET updated_at = clock_timestamp() + interval '1 second' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(id)]
    )
  end

  defp sample_invoice(form) do
    %{
      "formType" => form,
      "invoiceNo" => "OLD-12",
      "issuedOn" => "2026-10-12",
      "billToName" => "Lucy Mensah",
      "billToAddress" => "East Legon",
      "billToPhone" => "+233241234567",
      "billToEmail" => "lucy@example.com",
      "project" => "Post construction cleaning",
      "lines" => [
        %{"description" => "Cleaners", "qty" => 5, "days" => 3, "unitMinor" => 20_000},
        %{"description" => "Floor scrubber", "qty" => 1, "days" => 2, "unitMinor" => 55_000},
        %{"description" => "Vacuum", "qty" => 1, "days" => 1, "unitMinor" => 55_000},
        %{"description" => "Transport", "unitMinor" => 30_000}
      ],
      "adjustmentMinor" => -15_000,
      "notes" => "Old job"
    }
  end

  defp sample_advice(form) do
    %{
      "formType" => form,
      "adviceNo" => "PAY-2026-0231",
      "payPeriod" => "June 2026",
      "paymentDate" => "2026-07-02",
      "paidToName" => "Deborah Omari",
      "paidToAddress" => "Ablekuma, Accra",
      "paidToEmail" => "deborah.omari@gmail.com",
      "paidToPhone" => "+233558699102",
      "employeeId" => "EMP-0031",
      "role" => "Operations Manager",
      "department" => "Operations",
      "payType" => "Monthly salary",
      "earnings" => [
        %{"description" => "Base salary", "amountMinor" => 668_748},
        %{"description" => "Responsibility allowance", "amountMinor" => 80_000},
        %{"description" => "Performance bonus", "amountMinor" => 20_000}
      ],
      "reimbursements" => [
        %{"description" => "Field travel", "reference" => "RCP-2091", "amountMinor" => 25_600},
        %{
          "description" => "Onboarding bonus",
          "reference" => "RCP-2104",
          "amountMinor" => 15_000
        },
        %{"description" => "Airtime", "amountMinor" => 15_000}
      ],
      "deductions" => [
        %{"description" => "SSNIT", "amountMinor" => 42_281},
        %{"description" => "PAYE", "amountMinor" => 141_467}
      ],
      "payMethod" => "Mobile Money",
      "payAccount" => "+233558699102",
      "payNetwork" => "MTN",
      "payReference" => "MP2606-0231"
    }
  end
end
