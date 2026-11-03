defmodule Mithril.DirectAdminBillingOutreach do
  @moduledoc """
  Sends a custom invoice, asks the client to approve it, requests the service
  address, and introduces the proposed team.

  The invoice is not a booking. Approval is stored on the invoice. `booking_id`
  is reserved for the visit created from that approval.
  """

  require Logger

  alias Mithril.Auth
  alias Mithril.Auth.Phone
  alias Mithril.Auth.SMS
  alias Mithril.DirectAdminBilling
  alias Mithril.DirectAdminInvoices
  alias Mithril.Repo
  alias Mithril.WhatsApp.InvoiceTemplate

  @channels ~w(whatsapp sms email)
  @purposes ~w(invoice approval location team)
  @token ~r/^[0-9a-f]{64}$/

  def send(user_id, invoice_id, params) when is_map(params) do
    channel = params["channel"] || params[:channel]
    purpose = params["purpose"] || params[:purpose]

    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         true <- channel in @channels and purpose in @purposes,
         {:ok, invoice} <- DirectAdminBilling.fetch_invoice(invoice_id),
         :ok <- ready?(invoice, purpose),
         {:ok, claimed} <- claim_delivery(invoice, purpose) do
      result =
        with :ok <- deliver(user_id, claimed, channel, purpose),
             {:ok, updated} <- mark_sent(claimed["id"], channel, purpose) do
          {:ok, Map.merge(updated, %{"sent" => true, "channel" => channel, "purpose" => purpose})}
        end

      if match?({:error, _}, result) and purpose == "team" do
        release_team_claim(claimed["id"])
      end

      result
    else
      false -> {:error, :invalid_request}
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_team(user_id, invoice_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, workers} <- workers(params["workers"] || params[:workers]),
         {:ok, invoice} <- DirectAdminBilling.fetch_invoice(invoice_id),
         :ok <- team_editable?(invoice),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             UPDATE public.admin_billing_invoices
             SET proposed_workers = $2::jsonb, updated_at = now()
             WHERE id = $1::uuid AND team_sent_at IS NULL AND team_sending_at IS NULL
             """,
             [dump!(invoice_id), workers]
           ) do
      DirectAdminBilling.fetch_invoice(invoice_id)
    else
      :error -> {:error, :invalid_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:ok, %{num_rows: 0}} -> {:error, :team_already_sent}
      {:error, error} -> database_error(error)
    end
  end

  def public_show(token) when is_binary(token) do
    with :ok <- token?(token),
         {:ok, invoice} <- fetch_token(token) do
      {:ok, public_json(invoice)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def public_show(_), do: {:error, :invoice_not_found}

  def decide(token, params) when is_binary(token) and is_map(params) do
    decision = params["decision"] || params[:decision]
    note = params["note"] || params[:note]

    with :ok <- token?(token),
         {:ok, invoice} <- fetch_token(token),
         :ok <- open_for_decision?(invoice),
         {:ok, encoded_note} <- decision_note(decision, note),
         {:ok, _} <- write_decision(invoice["id"], decision, encoded_note) do
      fetch_public(token)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def decide(_, _), do: {:error, :invoice_not_found}

  def share_location(token, params) when is_binary(token) and is_map(params) do
    with :ok <- token?(token),
         {:ok, address} <- address(params["address"] || params[:address]),
         {:ok, invoice} <- fetch_token(token),
         :ok <- location_open?(invoice),
         {:ok, _} <- write_address(invoice["id"], address) do
      fetch_public(token)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def share_location(_, _), do: {:error, :invoice_not_found}

  def message(invoice, "invoice") when is_map(invoice) do
    """
    Instaclean invoice #{invoice["invoiceNo"]}

    Hi #{first_name(invoice["billToName"])}, your invoice is ready.

    #{invoice["project"]} · #{date_label(invoice["issuedOn"])}
    Total #{DirectAdminInvoices.money(invoice["totalMinor"])}

    View your invoice:
    #{invoice["viewUrl"]}
    """
    |> String.trim()
  end

  def message(invoice, "approval") when is_map(invoice) do
    """
    Instaclean invoice #{invoice["invoiceNo"]}

    Please approve this invoice, or tell us what to change.

    #{invoice["project"]} · #{date_label(invoice["issuedOn"])}
    Total #{DirectAdminInvoices.money(invoice["totalMinor"])}

    View your invoice:
    #{invoice["viewUrl"]}
    """
    |> String.trim()
  end

  def message(invoice, "location") when is_map(invoice) do
    """
    Instaclean

    Hi #{first_name(invoice["billToName"])}, where should we clean?

    Send the address here, or open the invoice to share it.
    #{invoice["viewUrl"]}
    """
    |> String.trim()
  end

  def message(invoice, "team") when is_map(invoice) do
    people =
      invoice["proposedWorkers"]
      |> List.wrap()
      |> Enum.map(fn worker -> "#{worker["name"]} · #{worker["role"]}" end)
      |> Enum.join("\n")

    """
    Instaclean

    Your team for this clean:

    #{people}

    See your team:
    #{invoice["viewUrl"]}
    """
    |> String.trim()
  end

  defp ready?(invoice, "approval") do
    if invoice["invoiceSentAt"], do: :ok, else: {:error, :invoice_not_sent}
  end

  defp ready?(invoice, "team") do
    cond do
      invoice["approvalStatus"] != "approved" -> {:error, :team_not_ready}
      invoice["proposedWorkers"] == [] -> {:error, :team_empty}
      true -> :ok
    end
  end

  defp ready?(_invoice, purpose) when purpose in ["invoice", "location"], do: :ok
  defp ready?(_, _), do: {:error, :invalid_request}

  defp team_editable?(invoice) do
    if invoice["approvalStatus"] == "approved" and invoice["teamSentAt"] do
      {:error, :team_already_sent}
    else
      :ok
    end
  end

  defp claim_delivery(invoice, "team") do
    case Repo.query(
           """
           UPDATE public.admin_billing_invoices
           SET team_sending_at = now()
           WHERE id = $1::uuid AND approval_status = 'approved'
             AND team_sent_at IS NULL AND team_sending_at IS NULL
             AND jsonb_array_length(proposed_workers) > 0
           RETURNING id
           """,
           [dump!(invoice["id"])]
         ) do
      {:ok, %{num_rows: 1}} -> DirectAdminBilling.fetch_invoice(invoice["id"])
      {:ok, _} -> {:error, :team_already_sent}
      {:error, error} -> database_error(error)
    end
  end

  defp claim_delivery(invoice, _purpose), do: {:ok, invoice}

  defp release_team_claim(invoice_id) do
    Repo.query(
      "UPDATE public.admin_billing_invoices SET team_sending_at = NULL WHERE id = $1::uuid AND team_sent_at IS NULL",
      [dump!(invoice_id)]
    )
  end

  defp deliver(admin_id, invoice, "whatsapp", purpose) do
    case Phone.normalize(invoice["billToPhone"] || "") do
      {:ok, phone} ->
        if purpose == "invoice" do
          InvoiceTemplate.deliver(
            admin_id,
            invoice,
            phone,
            message(invoice, purpose),
            DirectAdminInvoices.money(invoice["totalMinor"])
          )
        else
          case Mithril.DirectAdminWhatsApp.deliver_as_staff(admin_id, %{
                 "phoneE164" => phone,
                 "body" => message(invoice, purpose)
               }) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      :error ->
        {:error, :missing_phone}
    end
  end

  defp deliver(_admin_id, invoice, "sms", purpose) do
    case Phone.normalize(invoice["billToPhone"] || "") do
      {:ok, phone} ->
        case SMS.send_message(phone, message(invoice, purpose)) do
          :ok -> :ok
          {:error, :sms_not_configured} -> {:error, :sms_not_configured}
          {:error, _} -> {:error, :sms_delivery_failed}
        end

      :error ->
        {:error, :missing_phone}
    end
  end

  defp deliver(_admin_id, invoice, "email", purpose) do
    email = invoice["billToEmail"]

    if is_binary(email) and email != "" do
      send_email(invoice, purpose)
    else
      {:error, :missing_email}
    end
  end

  defp deliver(_, _, _, _), do: {:error, :invalid_request}

  defp mark_sent(invoice_id, channel, purpose) do
    {at_column, channel_column} = sent_columns(purpose)

    status_sql =
      if purpose == "invoice" do
        """
        , approval_status = CASE
            WHEN approval_status = 'approved' THEN approval_status
            ELSE 'awaiting_approval'
          END,
          approval_note = CASE
            WHEN approval_status = 'approved' THEN approval_note
            ELSE NULL
          END
        """
      else
        ""
      end

    team_sql = if purpose == "team", do: ", team_sending_at = NULL", else: ""

    case Repo.query(
           """
           UPDATE public.admin_billing_invoices
           SET #{at_column} = now(), #{channel_column} = $2#{status_sql}#{team_sql}, updated_at = now()
           WHERE id = $1::uuid
           """,
           [dump!(invoice_id), channel]
         ) do
      {:ok, _} -> DirectAdminBilling.fetch_invoice(invoice_id)
      {:error, error} -> database_error(error)
    end
  end

  defp sent_columns("invoice"), do: {"invoice_sent_at", "invoice_sent_channel"}
  defp sent_columns("approval"), do: {"approval_requested_at", "approval_requested_channel"}
  defp sent_columns("location"), do: {"location_requested_at", "location_requested_channel"}
  defp sent_columns("team"), do: {"team_sent_at", "team_sent_channel"}

  defp open_for_decision?(invoice) do
    cond do
      invoice["approvalStatus"] == "approved" -> {:error, :already_approved}
      is_nil(invoice["invoiceSentAt"]) -> {:error, :invoice_not_sent}
      invoice["approvalStatus"] in ["awaiting_approval", "changes_requested"] -> :ok
      true -> {:error, :invoice_not_sent}
    end
  end

  defp location_open?(invoice) do
    if invoice["locationRequestedAt"], do: :ok, else: {:error, :location_not_requested}
  end

  defp decision_note("approve", _note), do: {:ok, nil}

  defp decision_note("changes", note) when is_binary(note) do
    trimmed = String.trim(note)

    cond do
      trimmed == "" -> {:error, :invalid_request}
      String.length(trimmed) > 500 -> {:error, :invalid_request}
      true -> {:ok, trimmed}
    end
  end

  defp decision_note("changes", _), do: {:error, :invalid_request}
  defp decision_note(_, _), do: {:error, :invalid_request}

  defp write_decision(invoice_id, "approve", _note) do
    Repo.query(
      """
      UPDATE public.admin_billing_invoices
      SET approval_status = 'approved', approval_note = NULL, approved_at = now(), updated_at = now()
      WHERE id = $1::uuid AND approval_status <> 'approved'
      """,
      [dump!(invoice_id)]
    )
  end

  defp write_decision(invoice_id, "changes", note) do
    Repo.query(
      """
      UPDATE public.admin_billing_invoices
      SET approval_status = 'changes_requested', approval_note = $2, approved_at = NULL, updated_at = now()
      WHERE id = $1::uuid AND approval_status <> 'approved'
      """,
      [dump!(invoice_id), note]
    )
  end

  defp write_address(invoice_id, address) do
    Repo.query(
      """
      UPDATE public.admin_billing_invoices
      SET service_address = $2, updated_at = now()
      WHERE id = $1::uuid
      """,
      [dump!(invoice_id), address]
    )
  end

  defp fetch_public(token) do
    case fetch_token(token) do
      {:ok, invoice} -> {:ok, public_json(invoice)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_token(token) do
    case Repo.query("#{DirectAdminBilling.invoice_select()} WHERE public_token = $1 LIMIT 1", [
           token
         ]) do
      {:ok, %{rows: [row]}} -> {:ok, DirectAdminBilling.present_invoice(row)}
      {:ok, %{rows: []}} -> {:error, :invoice_not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp public_json(invoice) do
    %{
      "invoiceNo" => invoice["invoiceNo"],
      "issuedOn" => invoice["issuedOn"],
      "billToName" => invoice["billToName"],
      "billToAddress" => invoice["billToAddress"],
      "project" => invoice["project"],
      "lines" => invoice["lines"] || [],
      "adjustmentMinor" => invoice["adjustmentMinor"],
      "subtotalMinor" => invoice["subtotalMinor"],
      "totalMinor" => invoice["totalMinor"],
      "currency" => invoice["currency"] || "GHS",
      "notes" => invoice["notes"],
      "signatoryRole" => invoice["signatoryRole"],
      "approvalStatus" => invoice["approvalStatus"],
      "approvalNote" => invoice["approvalNote"],
      "serviceAddress" => invoice["serviceAddress"],
      "proposedWorkers" =>
        if(invoice["teamSentAt"], do: invoice["proposedWorkers"] || [], else: []),
      "invoiceSent" => not is_nil(invoice["invoiceSentAt"]),
      "locationRequested" => not is_nil(invoice["locationRequestedAt"]),
      "teamSent" => not is_nil(invoice["teamSentAt"])
    }
  end

  defp workers(list) when is_list(list) and length(list) <= 8 do
    Enum.reduce_while(list, {:ok, []}, fn worker, {:ok, acc} ->
      case worker_pair(worker) do
        {:ok, encoded} -> {:cont, {:ok, acc ++ [encoded]}}
        :error -> {:halt, {:error, :invalid_workers}}
      end
    end)
  end

  defp workers(_), do: {:error, :invalid_workers}

  defp worker_pair(worker) when is_map(worker) do
    with {:ok, name} <- required_text(worker["name"] || worker[:name], 80),
         {:ok, role} <- required_text(worker["role"] || worker[:role], 40) do
      {:ok, %{"name" => name, "role" => role}}
    else
      _ -> :error
    end
  end

  defp worker_pair(_), do: :error

  defp address(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.length(trimmed) < 3 -> {:error, :invalid_request}
      String.length(trimmed) > 500 -> {:error, :invalid_request}
      true -> {:ok, trimmed}
    end
  end

  defp address(_), do: {:error, :invalid_request}

  defp send_email(invoice, purpose) do
    api_key = Application.get_env(:mithril, :resend_api_key, "") |> to_string() |> String.trim()

    if api_key == "" do
      {:error, :email_not_configured}
    else
      body = %{
        from:
          Application.get_env(
            :mithril,
            :resend_from,
            "Instaclean <noreply@update.tryinstaclean.com>"
          ),
        to: [invoice["billToEmail"]],
        subject: email_subject(invoice, purpose),
        html: email_html(invoice, purpose)
      }

      case Req.post(resend_url(), resend_options(body, api_key)) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _ -> {:error, :email_delivery_failed}
      end
    end
  end

  defp email_subject(invoice, "approval"),
    do: "Please approve Instaclean invoice #{invoice["invoiceNo"]}"

  defp email_subject(_invoice, "location"),
    do: "Where should Instaclean clean?"

  defp email_subject(_invoice, "team"),
    do: "Your Instaclean team"

  defp email_subject(invoice, _),
    do: "Instaclean invoice #{invoice["invoiceNo"]}"

  defp email_html(invoice, purpose) do
    text =
      message(invoice, purpose)
      |> String.split("\n")
      |> Enum.map(&"<p>#{escape(&1)}</p>")
      |> Enum.join()

    "<div style=\"font-family: sans-serif; color: #171e38;\">#{text}</div>"
  end

  defp resend_url do
    Application.get_env(:mithril, :resend_api_url, "https://api.resend.com/emails")
  end

  defp resend_options(body, api_key) do
    options = [json: body, auth: {:bearer, api_key}]
    extra = Application.get_env(:mithril, :resend_req_options, [])
    if is_list(extra), do: Keyword.merge(options, extra), else: options
  end

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp first_name(name) when is_binary(name) do
    case String.split(String.trim(name), ~r/\s+/, parts: 2) do
      [first | _] when first != "" -> first
      _ -> "there"
    end
  end

  defp first_name(_), do: "there"

  defp date_label(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), date.month - 1)
        "#{date.day} #{month} #{date.year}"

      _ ->
        value
    end
  end

  defp date_label(_), do: "the invoice date"

  defp token?(token) do
    if String.match?(token, @token), do: :ok, else: {:error, :invoice_not_found}
  end

  defp required_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> :error
      String.length(trimmed) > max -> :error
      true -> {:ok, trimmed}
    end
  end

  defp required_text(_, _), do: :error

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp dump!(value) do
    {:ok, dumped} = Ecto.UUID.dump(value)
    dumped
  end

  defp database_error(error) do
    Logger.error("Billing invoice outreach database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
