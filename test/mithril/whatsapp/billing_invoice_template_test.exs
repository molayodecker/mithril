defmodule Mithril.WhatsApp.BillingInvoiceTemplateTest do
  use ExUnit.Case, async: false

  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.Repo
  alias Mithril.WhatsApp.BillingInvoiceTemplate

  @token "a1b2c3d4e5f6789012345678abcdef0123456789abcdef0123456789abcdef01"

  setup do
    Application.put_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")

    for key <- [
          :twilio_template_billing_invoice,
          :twilio_template_billing_invoice_approval,
          :twilio_template_billing_invoice_location,
          :twilio_template_billing_invoice_team
        ] do
      Application.delete_env(:mithril, key)
    end

    :ok
  end

  test "each billing message has its own template and button" do
    expected = %{
      "invoice" => {"instaclean_billing_invoice", "View invoice", "Tap below to view it."},
      "approval" =>
        {"instaclean_billing_invoice_approval", "Review invoice", "request a change."},
      "location" =>
        {"instaclean_billing_invoice_location", "Share address", "share the address."},
      "team" => {"instaclean_billing_invoice_team", "See your team", "see them."}
    }

    for {purpose, {name, button, ending}} <- expected do
      definition = BillingInvoiceTemplate.definition(purpose)
      action = hd(definition["types"]["twilio/call-to-action"]["actions"])
      body = definition["types"]["twilio/call-to-action"]["body"]

      assert definition["friendly_name"] == name
      assert action["title"] == button
      assert String.ends_with?(body, ending)
      refute String.match?(body, ~r/\{\{\d+\}\}\z/)

      assert action["url"] ==
               "https://direct.tryinstaclean.com/{{#{map_size(definition["variables"])}}}"
    end
  end

  test "template variables keep the public invoice path" do
    invoice = %{
      "billToName" => " Ama\nMensah ",
      "invoiceNo" => "1042",
      "project" => "Deep {clean}",
      "issuedOn" => "2026-11-06",
      "totalMinor" => 185_000,
      "proposedWorkers" => [
        %{"name" => "Akosua Boateng"},
        %{"name" => "Kwame Owusu"}
      ],
      "viewUrl" => "https://direct.tryinstaclean.com/invoices/#{@token}"
    }

    assert BillingInvoiceTemplate.variables("invoice", invoice, "invoices/#{@token}")["5"] ==
             "invoices/#{@token}"

    assert BillingInvoiceTemplate.variables("invoice", invoice, "invoices/#{@token}")["3"] ==
             "Deep clean"

    assert BillingInvoiceTemplate.variables("location", invoice, "invoices/#{@token}")["3"] ==
             "6 Nov 2026"

    assert BillingInvoiceTemplate.variables("team", invoice, "invoices/#{@token}")["3"] ==
             "Akosua Boateng, Kwame Owusu"
  end

  test "the first send creates the template and a retry only resubmits approval" do
    Fixtures.checkout!()

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.whatsapp_content_templates (
      name text PRIMARY KEY,
      content_sid text NOT NULL,
      approval_status text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!(
      "DELETE FROM public.whatsapp_content_templates WHERE name = 'instaclean_billing_invoice_approval'"
    )

    caller = self()

    Application.put_env(:mithril, :twilio_content_http, fn
      :create, body ->
        send(caller, {:created, body["friendly_name"]})
        {:ok, "HXapproval"}

      :approve, _body ->
        send(caller, :approval_attempt)

        if Process.get(:approval_failed_once) do
          :ok
        else
          Process.put(:approval_failed_once, true)
          {:error, :temporary_failure}
        end
    end)

    assert {:error, :temporary_failure} = BillingInvoiceTemplate.ensure("approval")
    assert {:ok, "HXapproval"} = BillingInvoiceTemplate.ensure("approval")
    assert_received {:created, "instaclean_billing_invoice_approval"}
    assert_received :approval_attempt
    assert_received :approval_attempt
    refute_received {:created, _}

    assert [["submitted"]] =
             Repo.query!(
               "SELECT approval_status FROM public.whatsapp_content_templates WHERE name = 'instaclean_billing_invoice_approval'"
             ).rows
  end
end
