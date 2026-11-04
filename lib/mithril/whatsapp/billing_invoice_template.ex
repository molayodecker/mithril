defmodule Mithril.WhatsApp.BillingInvoiceTemplate do
  @moduledoc """
  WhatsApp templates for a billing invoice.

  Each purpose has its own template and button. The button URL is
  `{DIRECT_PUBLIC_URL}/{{n}}`, where the variable is `invoices/{token}`.
  The page does not require a sign-in.

  Set the matching `TWILIO_TEMPLATE_BILLING_INVOICE*` Content SID after
  WhatsApp approves the template. When it is unset, the first send creates
  the template and submits it for approval. Until WhatsApp accepts it,
  delivery falls back to the session message.
  """

  alias Mithril.DirectAdminInvoices
  alias Mithril.DirectAdminWhatsApp
  alias Mithril.Repo
  alias Mithril.WhatsApp.ContentApi
  alias Mithril.WhatsApp.InvoiceTemplate
  alias Mithril.WhatsApp.PaymentTemplate

  @sample_token "a1b2c3d4e5f6789012345678abcdef0123456789abcdef0123456789abcdef01"
  @sample_path "invoices/#{@sample_token}"

  @templates %{
    "invoice" => %{
      name: "instaclean_billing_invoice",
      config: :twilio_template_billing_invoice,
      button: "View invoice",
      body:
        "Hello {{1}}, your Instaclean invoice {{2}} for {{3}} is {{4}}. Tap below to view it.",
      samples: %{
        "1" => "Ama Mensah",
        "2" => "1042",
        "3" => "Deep clean",
        "4" => "GHS 1,850.00",
        "5" => @sample_path
      }
    },
    "approval" => %{
      name: "instaclean_billing_invoice_approval",
      config: :twilio_template_billing_invoice_approval,
      button: "Review invoice",
      body:
        "Hello {{1}}, please approve Instaclean invoice {{2}} for {{3}}. The total is {{4}}. Tap below to approve it or request a change.",
      samples: %{
        "1" => "Ama Mensah",
        "2" => "1042",
        "3" => "Deep clean",
        "4" => "GHS 1,850.00",
        "5" => @sample_path
      }
    },
    "location" => %{
      name: "instaclean_billing_invoice_location",
      config: :twilio_template_billing_invoice_location,
      button: "Share address",
      body:
        "Hello {{1}}, where should Instaclean clean for invoice {{2}} on {{3}}? Tap below to share the address.",
      samples: %{
        "1" => "Ama Mensah",
        "2" => "1042",
        "3" => "6 Nov 2026",
        "4" => @sample_path
      }
    },
    "team" => %{
      name: "instaclean_billing_invoice_team",
      config: :twilio_template_billing_invoice_team,
      button: "See your team",
      body:
        "Hello {{1}}, your Instaclean team for invoice {{2}} is {{3}}. Tap below to see them.",
      samples: %{
        "1" => "Ama Mensah",
        "2" => "1042",
        "3" => "Akosua Boateng, Kwame Owusu",
        "4" => @sample_path
      }
    }
  }

  def purposes, do: Map.keys(@templates)

  def definition(purpose) when is_map_key(@templates, purpose) do
    spec = Map.fetch!(@templates, purpose)

    %{
      "friendly_name" => spec.name,
      "language" => "en",
      "variables" => spec.samples,
      "types" => %{
        "twilio/call-to-action" => %{
          "body" => spec.body,
          "actions" => [
            %{
              "type" => "URL",
              "title" => spec.button,
              "url" => "#{PaymentTemplate.public_base()}/{{#{path_key(spec)}}}"
            }
          ]
        }
      }
    }
  end

  def variables(purpose, invoice, path)
      when is_map_key(@templates, purpose) and is_binary(path) do
    name = clip(invoice["billToName"], 60, "Customer")
    number = clip(invoice["invoiceNo"], 40, "invoice")

    case purpose do
      "location" ->
        %{
          "1" => name,
          "2" => number,
          "3" => clip(InvoiceTemplate.due_label(invoice["issuedOn"]), 40, "the visit"),
          "4" => clip(path, 120, "")
        }

      "team" ->
        %{
          "1" => name,
          "2" => number,
          "3" => clip(team_label(invoice["proposedWorkers"]), 80, "your cleaners"),
          "4" => clip(path, 120, "")
        }

      _ ->
        %{
          "1" => name,
          "2" => number,
          "3" => clip(invoice["project"], 80, "your service"),
          "4" => clip(DirectAdminInvoices.money(invoice["totalMinor"]), 40, "the amount due"),
          "5" => clip(path, 120, "")
        }
    end
  end

  def deliver(admin_uid, invoice, phone, purpose, readable_body)
      when is_binary(admin_uid) and is_map(invoice) and is_binary(phone) and
             is_binary(readable_body) and is_map_key(@templates, purpose) do
    params = %{"phoneE164" => phone, "body" => readable_body}

    case prepared(purpose, invoice) do
      {:ok, sid, template_variables} ->
        case DirectAdminWhatsApp.deliver_content_as_staff(
               admin_uid,
               params,
               sid,
               template_variables
             ) do
          {:ok, _} -> :ok
          {:error, :template_rejected} -> session(admin_uid, params)
          {:error, reason} -> {:error, reason}
        end

      :session ->
        session(admin_uid, params)
    end
  end

  def ensure(purpose) when is_map_key(@templates, purpose) do
    spec = Map.fetch!(@templates, purpose)

    case env_sid(spec) do
      sid when is_binary(sid) -> {:ok, sid}
      _ -> ensure_stored(spec)
    end
  end

  defp prepared(purpose, invoice) do
    spec = Map.fetch!(@templates, purpose)

    with path when is_binary(path) <- InvoiceTemplate.path(invoice["viewUrl"]),
         template_variables <- variables(purpose, invoice, path),
         true <- template_variables[path_key(spec)] != "",
         {:ok, sid} <- ensure(purpose) do
      {:ok, sid, template_variables}
    else
      _ -> :session
    end
  end

  defp path_key(%{samples: samples}) do
    samples
    |> Map.keys()
    |> Enum.max_by(&String.to_integer/1)
  end

  defp team_label(workers) when is_list(workers) do
    workers
    |> Enum.map(fn worker -> worker["name"] || worker[:name] end)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(", ")
  end

  defp team_label(_), do: ""

  defp ensure_stored(spec) do
    case stored_template(spec.name) do
      {sid, "submitted"} when is_binary(sid) -> {:ok, sid}
      {sid, _status} when is_binary(sid) -> approve_and_mark(spec, sid)
      _ -> create(spec)
    end
  end

  defp create(spec) do
    case ContentApi.create(definition(purpose_for(spec))) do
      {:ok, sid} ->
        _ = store_sid(spec.name, sid)
        approve_and_mark(spec, sid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp purpose_for(spec) do
    Enum.find_value(@templates, fn {purpose, item} -> if item.name == spec.name, do: purpose end)
  end

  defp approve_and_mark(spec, sid) do
    case ContentApi.submit_approval(sid, spec.name) do
      :ok -> mark_submitted(spec.name, sid)
      {:ok, _} -> mark_submitted(spec.name, sid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_submitted(name, sid) do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             """
             UPDATE public.whatsapp_content_templates
             SET approval_status = 'submitted', updated_at = now()
             WHERE name = $1 AND content_sid = $2
             """,
             [name, sid]
           ) do
        {:ok, _} -> {:ok, sid}
        {:error, _} -> {:error, :template_not_created}
      end
    else
      {:ok, sid}
    end
  end

  defp env_sid(spec) do
    case Application.get_env(:mithril, spec.config) do
      sid when is_binary(sid) ->
        sid = String.trim(sid)
        if sid == "", do: nil, else: sid

      _ ->
        nil
    end
  end

  defp stored_template(name) do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             "SELECT content_sid, approval_status FROM public.whatsapp_content_templates WHERE name = $1",
             [name]
           ) do
        {:ok, %{rows: [[sid, status]]}} when is_binary(sid) and sid != "" -> {sid, status}
        _ -> nil
      end
    else
      nil
    end
  end

  defp store_sid(name, sid) do
    if table?("public.whatsapp_content_templates") do
      Repo.query(
        """
        INSERT INTO public.whatsapp_content_templates (name, content_sid, approval_status)
        VALUES ($1, $2, 'created')
        ON CONFLICT (name) DO UPDATE
          SET content_sid = EXCLUDED.content_sid,
              approval_status = 'created', updated_at = now()
        """,
        [name, sid]
      )
    else
      :ok
    end
  end

  defp table?(name) do
    case Repo.query("SELECT to_regclass($1)::text", [name]) do
      {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  defp session(admin_uid, params) do
    case DirectAdminWhatsApp.deliver_as_staff(admin_uid, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
