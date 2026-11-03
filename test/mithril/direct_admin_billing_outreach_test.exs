defmodule Mithril.DirectAdminBillingOutreachTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectAdminBilling
  alias Mithril.DirectAdminBillingOutreach
  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.Repo

  setup do
    Fixtures.checkout!()
    :ok
  end

  test "a saved invoice can be approved, changed, and given an address" do
    admin_id = Fixtures.insert_user!("admin")
    invoice_id = Ecto.UUID.generate()
    assert {:ok, saved} = DirectAdminBilling.upsert_invoice(admin_id, invoice_id, invoice())
    assert saved["approvalStatus"] == "draft"
    assert saved["publicToken"] =~ ~r/^[0-9a-f]{64}$/
    assert String.ends_with?(saved["viewUrl"], "/invoices/#{saved["publicToken"]}")

    assert {:error, :invoice_not_sent} =
             DirectAdminBillingOutreach.decide(saved["publicToken"], %{"decision" => "approve"})

    mark_sent!(invoice_id)

    assert {:ok, changed} =
             DirectAdminBillingOutreach.decide(saved["publicToken"], %{
               "decision" => "changes",
               "note" => "Please remove the transport line."
             })

    assert changed["approvalStatus"] == "changes_requested"
    assert changed["approvalNote"] == "Please remove the transport line."
    assert changed["invoiceSent"]

    assert {:ok, approved} =
             DirectAdminBillingOutreach.decide(saved["publicToken"], %{"decision" => "approve"})

    assert approved["approvalStatus"] == "approved"
    assert approved["approvalNote"] == nil

    assert {:error, :already_approved} =
             DirectAdminBilling.upsert_invoice(
               admin_id,
               invoice_id,
               Map.put(invoice(), "project", "Different service")
             )

    assert {:error, :already_approved} =
             DirectAdminBillingOutreach.decide(saved["publicToken"], %{"decision" => "approve"})

    assert {:error, :location_not_requested} =
             DirectAdminBillingOutreach.share_location(saved["publicToken"], %{
               "address" => "14 Jungle Road, East Legon"
             })

    Repo.query!(
      "UPDATE public.admin_billing_invoices SET location_requested_at = now() WHERE id = $1::uuid",
      [Ecto.UUID.dump!(invoice_id)]
    )

    assert {:ok, located} =
             DirectAdminBillingOutreach.share_location(saved["publicToken"], %{
               "address" => "14 Jungle Road, East Legon"
             })

    assert located["serviceAddress"] == "14 Jungle Road, East Legon"
    assert located["billToAddress"] == nil
  end

  test "the proposed team is saved and can be sent only after approval" do
    admin_id = Fixtures.insert_user!("admin")
    invoice_id = Ecto.UUID.generate()
    assert {:ok, saved} = DirectAdminBilling.upsert_invoice(admin_id, invoice_id, invoice())

    assert {:ok, with_team} =
             DirectAdminBillingOutreach.set_team(admin_id, invoice_id, %{
               "workers" => [%{"name" => "Akosua Boateng", "role" => "Cleaner"}]
             })

    assert with_team["proposedWorkers"] == [%{"name" => "Akosua Boateng", "role" => "Cleaner"}]

    assert {:error, :team_not_ready} =
             DirectAdminBillingOutreach.send(admin_id, invoice_id, %{
               "channel" => "email",
               "purpose" => "team"
             })

    assert String.contains?(
             DirectAdminBillingOutreach.message(saved, "invoice"),
             "View your invoice:"
           )
  end

  test "whatsapp send requires a phone number before any delivery" do
    admin_id = Fixtures.insert_user!("admin")
    invoice_id = Ecto.UUID.generate()
    payload = Map.put(invoice(), "billToPhone", nil)
    assert {:ok, _saved} = DirectAdminBilling.upsert_invoice(admin_id, invoice_id, payload)

    assert {:error, :missing_phone} =
             DirectAdminBillingOutreach.send(admin_id, invoice_id, %{
               "channel" => "whatsapp",
               "purpose" => "invoice"
             })
  end

  defp mark_sent!(invoice_id) do
    Repo.query!(
      """
      UPDATE public.admin_billing_invoices
      SET invoice_sent_at = now(), invoice_sent_channel = 'email', approval_status = 'awaiting_approval'
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(invoice_id)]
    )
  end

  defp invoice do
    %{
      "issuedOn" => "2026-11-06",
      "billToName" => "Ama Mensah",
      "billToPhone" => "+233244128801",
      "billToEmail" => "ama@household.example",
      "project" => "Deep clean",
      "lines" => [
        %{"description" => "Deep clean, 3-bedroom house", "unitMinor" => 120_000}
      ],
      "adjustmentMinor" => 0
    }
  end
end
