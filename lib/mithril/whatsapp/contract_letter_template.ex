defmodule Mithril.WhatsApp.ContractLetterTemplate do
  @moduledoc """
  WhatsApp template for a client service agreement.

  The button URL is `{DIRECT_PUBLIC_URL}/{{4}}`, where `{{4}}` is
  `letters/contract/{token}`. The page does not require a sign-in.

  Set `TWILIO_TEMPLATE_CONTRACT_LETTER` to the approved Twilio Content SID
  `instaclean_service_agreement`. Until WhatsApp approves that template,
  delivery falls back to a session message.
  """

  alias Mithril.DirectAdminWhatsApp
  alias Mithril.WhatsApp.PaymentTemplate

  @name "instaclean_service_agreement"
  @button "View agreement"
  @sample_token "a1b2c3d4e5f6789012345678abcdef0123456789abcdef0123456789abcdef01"

  def name, do: @name

  def body do
    "Hello {{1}}, your Instaclean service agreement {{2}} is {{3}} a month. Tap below to view it."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{
        "1" => "Ama Mensah",
        "2" => "LTR-2026-001",
        "3" => "GHS 4,000.00",
        "4" => "letters/contract/#{@sample_token}"
      },
      "types" => %{
        "twilio/call-to-action" => %{
          "body" => body(),
          "actions" => [
            %{
              "type" => "URL",
              "title" => @button,
              "url" => "#{public_base()}/{{4}}"
            }
          ]
        }
      }
    }
  end

  def variables(%{
        "customerName" => name,
        "letterNo" => number,
        "amountLabel" => amount,
        "path" => path
      }) do
    %{
      "1" => clip(name, 60, "Customer"),
      "2" => clip(number, 40, "agreement"),
      "3" => clip(amount, 40, "the monthly fee"),
      "4" => clip(path, 120, "")
    }
  end

  def content_sid do
    case Application.get_env(:mithril, :twilio_template_contract_letter) do
      sid when is_binary(sid) ->
        sid = String.trim(sid)
        if sid == "", do: nil, else: sid

      _ ->
        nil
    end
  end

  @doc """
  Sends the agreement template when its Content SID is configured and the link
  is a client letter. Otherwise sends the readable session text. A rejected
  template also falls back to that session text.
  """
  def deliver(admin_uid, letter, phone, readable_body, amount_label)
      when is_binary(admin_uid) and is_map(letter) and is_binary(phone) and
             is_binary(readable_body) and is_binary(amount_label) do
    params = %{"phoneE164" => phone, "body" => readable_body}

    with sid when is_binary(sid) <- content_sid(),
         path when is_binary(path) <- path(letter["viewUrl"]),
         variables <-
           variables(%{
             "customerName" => greeting(letter),
             "letterNo" => letter["letterNo"],
             "amountLabel" => amount_label,
             "path" => path
           }),
         true <- variables["4"] != "" do
      case DirectAdminWhatsApp.deliver_content_as_staff(admin_uid, params, sid, variables) do
        {:ok, _} -> :ok
        {:error, :template_rejected} -> session(admin_uid, params)
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> session(admin_uid, params)
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

  defp greeting(letter) do
    contact = letter["billingContact"]

    if is_binary(contact) and String.trim(contact) != "" do
      contact
    else
      letter["clientName"]
    end
  end

  defp path?(value) do
    String.match?(value, ~r/\Aletters\/contract\/[0-9a-f]{64}\z/)
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
