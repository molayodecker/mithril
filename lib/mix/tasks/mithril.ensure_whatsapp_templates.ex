defmodule Mix.Tasks.Mithril.EnsureWhatsappTemplates do
  @shortdoc "Create or reuse Twilio WhatsApp Content templates and submit approval"

  @moduledoc """
  Ensures every Mithril WhatsApp Content template exists and has been submitted
  for WhatsApp approval.

      mix mithril.ensure_whatsapp_templates

  When a `TWILIO_TEMPLATE_*` env SID is set, that template is reused. Otherwise
  the task creates the Content template, stores the SID in
  `whatsapp_content_templates`, and submits Meta approval.
  """

  use Mix.Task

  alias Mithril.WhatsApp.BillingInvoiceTemplate
  alias Mithril.WhatsApp.ContractLetterTemplate
  alias Mithril.WhatsApp.InvoiceTemplate
  alias Mithril.WhatsApp.JobOfferTemplate
  alias Mithril.WhatsApp.PaymentTemplate
  alias Mithril.WhatsApp.WorkerAddedTemplate

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    results =
      [
        {"payment_request", PaymentTemplate.ensure()},
        {"job_offer", JobOfferTemplate.ensure()},
        {"invoice", InvoiceTemplate.ensure()},
        {"contract_letter", ContractLetterTemplate.ensure()},
        {"worker_added", WorkerAddedTemplate.ensure()}
      ] ++
        Enum.map(BillingInvoiceTemplate.purposes(), fn purpose ->
          {"billing_invoice_#{purpose}", BillingInvoiceTemplate.ensure(purpose)}
        end)

    Enum.each(results, fn {name, result} ->
      Mix.shell().info("#{name}: #{inspect(result)}")
    end)

    case Enum.reject(results, fn {_name, result} -> match?({:ok, _}, result) end) do
      [] -> :ok
      failed -> Mix.raise("WhatsApp template ensure failed: #{inspect(failed)}")
    end
  end
end
