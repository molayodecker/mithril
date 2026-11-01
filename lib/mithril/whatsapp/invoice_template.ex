defmodule Mithril.WhatsApp.InvoiceTemplate do
  @moduledoc """
  WhatsApp template that gives a customer a public invoice link.

  The button URL is `{DIRECT_PUBLIC_URL}/{{6}}`, where `{{6}}` is
  `invoices/{token}` or `invoices/contract/{token}`. The page does not
  require a sign-in.

  Set `TWILIO_TEMPLATE_INVOICE` to the approved Twilio Content SID
  `instaclean_invoice`. Until WhatsApp approves that template, delivery
  falls back to a session message.
  """

  alias Mithril.DirectAdminWhatsApp
  alias Mithril.DirectContracts.Calendar
  alias Mithril.WhatsApp.PaymentTemplate

  @name "instaclean_invoice"
  @button "View invoice"
  @sample_token "a1b2c3d4e5f6789012345678abcdef0123456789abcdef0123456789abcdef01"

  def name, do: @name

  def body do
    "Hello {{1}}, your Instaclean invoice {{2}} for {{3}} is {{4}}, due {{5}}. Tap below to view it."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{
        "1" => "Ama Mensah",
        "2" => "INV-2026-001",
        "3" => "November 2026",
        "4" => "GHS 4,000.00",
        "5" => "30 Nov 2026",
        "6" => "invoices/contract/#{@sample_token}"
      },
      "types" => %{
        "twilio/call-to-action" => %{
          "body" => body(),
          "actions" => [
            %{
              "type" => "URL",
              "title" => @button,
              "url" => "#{public_base()}/{{6}}"
            }
          ]
        }
      }
    }
  end

  def variables(%{
        "customerName" => name,
        "invoiceNo" => number,
        "description" => description,
        "amountLabel" => amount,
        "dueLabel" => due,
        "path" => path
      }) do
    %{
      "1" => clip(name, 60, "Customer"),
      "2" => clip(number, 40, "invoice"),
      "3" => clip(description, 80, "your service"),
      "4" => clip(amount, 40, "the amount due"),
      "5" => clip(due, 40, "on receipt"),
      "6" => clip(path, 120, "")
    }
  end

  def content_sid do
    case Application.get_env(:mithril, :twilio_template_invoice) do
      sid when is_binary(sid) ->
        sid = String.trim(sid)
        if sid == "", do: nil, else: sid

      _ ->
        nil
    end
  end

  @doc """
  Sends the invoice template when its Content SID is configured and the public
  path is one of the two invoice links. Otherwise sends the readable session text.
  A rejected template also falls back to that session text.
  """
  def deliver(admin_uid, invoice, phone, readable_body, amount_label)
      when is_binary(admin_uid) and is_map(invoice) and is_binary(phone) and
             is_binary(readable_body) and is_binary(amount_label) do
    params = %{"phoneE164" => phone, "body" => readable_body}

    with sid when is_binary(sid) <- content_sid(),
         path when is_binary(path) <- path(invoice["viewUrl"]),
         variables <-
           variables(%{
             "customerName" => greeting(invoice),
             "invoiceNo" => invoice["invoiceNo"],
             "description" => invoice["project"],
             "amountLabel" => amount_label,
             "dueLabel" => due_label(invoice["dueOn"]),
             "path" => path
           }),
         true <- variables["6"] != "" do
      case DirectAdminWhatsApp.deliver_content_as_staff(admin_uid, params, sid, variables) do
        {:ok, _} -> :ok
        {:error, :template_rejected} -> session(admin_uid, params)
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> session(admin_uid, params)
    end
  end

  def due_label(value) do
    case Calendar.parse_date(value) do
      {:ok, date} ->
        month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), date.month - 1)
        "#{date.day} #{month} #{date.year}"

      :error ->
        "on receipt"
    end
  end

  def path(url) when is_binary(url) do
    prefix = public_base() <> "/"

    if String.starts_with?(url, prefix) do
      relative = String.replace_prefix(url, prefix, "")
      if path?(relative), do: relative, else: nil
    else
      nil
    end
  end

  def path(_), do: nil

  def public_base, do: PaymentTemplate.public_base()

  defp session(admin_uid, params) do
    case DirectAdminWhatsApp.deliver_as_staff(admin_uid, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp greeting(invoice) do
    contact = invoice["billingContact"]

    if is_binary(contact) and String.trim(contact) != "" do
      contact
    else
      invoice["billToName"]
    end
  end

  defp path?(value) do
    String.match?(value, ~r/\Ainvoices\/(contract\/)?[0-9a-f]{64}\z/)
  end

  defp clip(value, max, fallback) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/[{}]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, max)

    if cleaned == "", do: fallback, else: cleaned
  end
end
