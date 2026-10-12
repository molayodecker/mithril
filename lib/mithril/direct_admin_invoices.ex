defmodule Mithril.DirectAdminInvoices do
  @moduledoc "Staff-created job invoices, with WhatsApp and email delivery."

  require Logger

  alias Mithril.Auth
  alias Mithril.Auth.Phone
  alias Mithril.DirectAdminWhatsApp
  alias Mithril.Repo

  @max_minor 2_147_483_647
  @min_minor -2_147_483_648

  def show(user_id, booking_id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(admin_uid) do
      fetch_for_booking(bid)
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def public_show(token) when is_binary(token) do
    if String.match?(token, ~r/^[0-9a-f]{64}$/) do
      case Repo.query(
             "#{invoice_select()} WHERE public_token = $1 LIMIT 1",
             [token]
           ) do
        {:ok, %{rows: [row]}} -> {:ok, present(row)}
        {:ok, %{rows: []}} -> {:error, :invoice_not_found}
        {:error, error} -> database_error(error)
      end
    else
      {:error, :invoice_not_found}
    end
  end

  def public_show(_), do: {:error, :invoice_not_found}

  def upsert(user_id, booking_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, bid} <- dump_uuid(booking_id),
         :ok <- require_admin(admin_uid),
         {:ok, payload} <- invoice_payload(params) do
      case Repo.query(
             """
             SELECT public.upsert_admin_job_invoice(
               p_booking_id := $1::uuid,
               p_recorded_by := $2::uuid,
               p_invoice := $3::jsonb
             )
             """,
             [bid, admin_uid, payload]
           ) do
        {:ok, %{rows: [[invoice]]}} when is_map(invoice) ->
          {:ok, with_view_url(invoice)}

        {:error, error} ->
          map_rpc_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def send(user_id, booking_id, params) when is_map(params) do
    channel = params["channel"] || params[:channel]

    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, invoice} <- show(user_id, booking_id),
         :ok <- deliver(admin_uid, invoice, channel) do
      mark_sent(invoice["bookingId"], channel, invoice["updatedAt"])
      {:ok, %{"ok" => true, "channel" => channel, "sent" => true}}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def line_total_minor(nil, nil, unit)
      when is_integer(unit) and unit > 0 and unit <= @max_minor,
      do: {:ok, unit}

  def line_total_minor(qty, days, unit)
      when is_integer(qty) and is_integer(days) and is_integer(unit) and qty > 0 and
             qty <= 10_000 and days > 0 and days <= 10_000 and unit > 0 and unit <= @max_minor do
    total = qty * days * unit
    if total <= @max_minor, do: {:ok, total}, else: :error
  end

  def line_total_minor(_, _, _), do: :error

  def whatsapp_message(invoice, url) when is_map(invoice) and is_binary(url) do
    header = """
    Instaclean invoice #{invoice["invoiceNo"]}
    #{invoice["project"]} for #{invoice["billToName"]}
    """

    footer = """
    Total due: #{money(invoice["totalMinor"])}

    View your invoice:
    #{url}
    """

    lines =
      invoice["lines"]
      |> List.wrap()
      |> Enum.map(&line_text/1)

    body = Enum.join([String.trim(header), Enum.join(lines, "\n"), String.trim(footer)], "\n\n")

    if String.length(body) <= 1900 do
      body
    else
      # Reserve room for the total and public link before adding item descriptions.
      fixed = Enum.join([String.trim(header), String.trim(footer)], "\n\n")
      allowance = max(0, 1900 - String.length(fixed) - 6)

      {selected, _remaining} =
        Enum.reduce_while(lines, {[], allowance}, fn line, {acc, remaining} ->
          needed = String.length(line) + 1

          if needed <= remaining do
            {:cont, {[line | acc], remaining - needed}}
          else
            {:halt, {acc, remaining}}
          end
        end)

      Enum.join(
        [String.trim(header), Enum.join(Enum.reverse(selected), "\n"), "…", String.trim(footer)],
        "\n\n"
      )
    end
  end

  defp fetch_for_booking(bid) do
    case Repo.query("#{invoice_select()} WHERE booking_id = $1::uuid LIMIT 1", [bid]) do
      {:ok, %{rows: [row]}} -> {:ok, present(row)}
      {:ok, %{rows: []}} -> {:error, :invoice_not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp invoice_select do
    """
    SELECT id, booking_id, public_token, invoice_no, issued_on::text, bill_to_name,
           bill_to_address, bill_to_phone, bill_to_email, project, lines,
           adjustment_minor, subtotal_minor, total_minor, currency, notes,
           last_whatsapp_sent_at, last_email_sent_at, updated_at
    FROM public.job_invoices
    """
  end

  defp present(row) do
    [
      id,
      booking_id,
      token,
      invoice_no,
      issued_on,
      name,
      address,
      phone,
      email,
      project,
      lines,
      adjustment,
      subtotal,
      total,
      currency,
      notes,
      whatsapp_at,
      email_at,
      updated_at
    ] = row

    with_view_url(%{
      "id" => uuid_string(id),
      "bookingId" => uuid_string(booking_id),
      "publicToken" => token,
      "invoiceNo" => invoice_no,
      "issuedOn" => issued_on,
      "billToName" => name,
      "billToAddress" => address,
      "billToPhone" => phone,
      "billToEmail" => email,
      "project" => project,
      "lines" => lines || [],
      "adjustmentMinor" => adjustment,
      "subtotalMinor" => subtotal,
      "totalMinor" => total,
      "currency" => currency || "GHS",
      "notes" => notes,
      "lastWhatsappSentAt" => timestamp(whatsapp_at),
      "lastEmailSentAt" => timestamp(email_at),
      "updatedAt" => timestamp(updated_at)
    })
  end

  defp with_view_url(invoice) when is_map(invoice) do
    token = invoice["publicToken"] || invoice["public_token"]
    Map.put(invoice, "viewUrl", view_url(token))
  end

  defp deliver(admin_uid, invoice, "whatsapp") do
    phone = invoice["billToPhone"]

    if is_binary(phone) and phone != "" do
      body = whatsapp_message(invoice, invoice["viewUrl"])

      case DirectAdminWhatsApp.deliver_as_staff(admin_uid, %{
             "phoneE164" => phone,
             "body" => body
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_phone}
    end
  end

  defp deliver(_admin_uid, invoice, "email") do
    email = invoice["billToEmail"]

    if is_binary(email) and email != "" do
      send_email(invoice)
    else
      {:error, :missing_email}
    end
  end

  defp deliver(_, _, _), do: {:error, :invalid_request}

  defp send_email(invoice) do
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
        subject: "Instaclean invoice #{invoice["invoiceNo"]}",
        html: email_html(invoice)
      }

      case Req.post(resend_url(), resend_options(body, api_key)) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _ -> {:error, :email_delivery_failed}
      end
    end
  end

  defp resend_url do
    Application.get_env(:mithril, :resend_api_url, "https://api.resend.com/emails")
  end

  defp resend_options(body, api_key) do
    options = [json: body, auth: {:bearer, api_key}]
    extra = Application.get_env(:mithril, :resend_req_options, [])
    if is_list(extra), do: Keyword.merge(options, extra), else: options
  end

  defp mark_sent(booking_id, channel, updated_at) do
    column =
      case channel do
        "whatsapp" -> "last_whatsapp_sent_at"
        "email" -> "last_email_sent_at"
      end

    with {:ok, bid} <- Ecto.UUID.dump(booking_id),
         {:ok, sent_version, _offset} <- DateTime.from_iso8601(updated_at),
         {:ok, _} <-
           Repo.query(
             "UPDATE public.job_invoices SET #{column} = now() WHERE booking_id = $1::uuid AND updated_at = $2::timestamptz",
             [bid, sent_version]
           ) do
      :ok
    else
      :error -> Logger.error("Could not record invoice send: invalid booking id")
      {:error, error} -> Logger.error("Could not record invoice send: #{inspect(error)}")
    end
  end

  defp invoice_payload(params) do
    with {:ok, lines} <- lines_payload(params["lines"] || params[:lines]),
         {:ok, adjustment} <- adjustment(params["adjustmentMinor"] || params[:adjustmentMinor]),
         {:ok, issued_on} <- issued_on(params["issuedOn"] || params[:issuedOn]),
         {:ok, name} <- required_text(params["billToName"] || params[:billToName], 160),
         {:ok, project} <- required_text(params["project"] || params[:project], 160),
         {:ok, address} <- optional_text(params["billToAddress"] || params[:billToAddress], 500),
         {:ok, phone} <- optional_phone(params["billToPhone"] || params[:billToPhone]),
         {:ok, email} <- optional_email(params["billToEmail"] || params[:billToEmail]),
         {:ok, notes} <- optional_text(params["notes"] || params[:notes], 2000),
         {:ok, invoice_no} <- optional_text(params["invoiceNo"] || params[:invoiceNo], 40) do
      {:ok,
       %{
         "invoiceNo" => invoice_no,
         "issuedOn" => issued_on,
         "billToName" => name,
         "billToAddress" => address,
         "billToPhone" => phone,
         "billToEmail" => email,
         "project" => project,
         "lines" => lines,
         "adjustmentMinor" => adjustment,
         "notes" => notes
       }}
    end
  end

  defp lines_payload(lines) when is_list(lines) and lines != [] and length(lines) <= 20 do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case line_payload(line) do
        {:ok, encoded} -> {:cont, {:ok, acc ++ [encoded]}}
        :error -> {:halt, {:error, :invalid_lines}}
      end
    end)
  end

  defp lines_payload(_), do: {:error, :invalid_lines}

  defp line_payload(line) when is_map(line) do
    description = line["description"] || line[:description]
    unit = line["unitMinor"] || line[:unitMinor]
    qty = blank_count(line["qty"] || line[:qty])
    days = blank_count(line["days"] || line[:days])

    with {:ok, text} <- required_text(description, 200),
         true <- is_integer(unit) and unit > 0,
         {:ok, _total} <- line_total_minor(qty, days, unit) do
      {:ok, %{"description" => text, "qty" => qty, "days" => days, "unitMinor" => unit}}
    else
      _ -> :error
    end
  end

  defp line_payload(_), do: :error

  defp blank_count(nil), do: nil
  defp blank_count(value) when is_integer(value), do: value

  defp blank_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> :invalid
    end
  end

  defp blank_count(_), do: :invalid

  defp adjustment(value) when is_integer(value) and value >= @min_minor and value <= @max_minor,
    do: {:ok, value}

  defp adjustment(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> adjustment(parsed)
      _ -> {:error, :invalid_invoice}
    end
  end

  defp adjustment(_), do: {:error, :invalid_invoice}

  defp issued_on(value) when is_binary(value) do
    if String.match?(value, ~r/^\d{4}-\d{2}-\d{2}$/) do
      case Date.from_iso8601(value) do
        {:ok, _} -> {:ok, value}
        _ -> {:error, :invalid_invoice}
      end
    else
      {:error, :invalid_invoice}
    end
  end

  defp issued_on(_), do: {:error, :invalid_invoice}

  defp required_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, :invalid_invoice}
      String.length(trimmed) > max -> {:error, :invalid_invoice}
      true -> {:ok, trimmed}
    end
  end

  defp required_text(_, _), do: {:error, :invalid_invoice}

  defp optional_text(nil, _max), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > max -> {:error, :invalid_invoice}
      true -> {:ok, trimmed}
    end
  end

  defp optional_text(_, _), do: {:error, :invalid_invoice}

  defp optional_phone(nil), do: {:ok, nil}

  defp optional_phone(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:ok, nil}

      true ->
        case Phone.normalize(trimmed) do
          {:ok, e164} -> {:ok, e164}
          :error -> {:error, :invalid_phone}
        end
    end
  end

  defp optional_phone(_), do: {:error, :invalid_phone}

  defp optional_email(nil), do: {:ok, nil}

  defp optional_email(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.downcase()

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > 200 -> {:error, :invalid_invoice}
      String.match?(trimmed, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) -> {:ok, trimmed}
      true -> {:error, :invalid_email}
    end
  end

  defp optional_email(_), do: {:error, :invalid_email}

  defp line_text(line) do
    qty = line["qty"]
    days = line["days"]
    amount = money(line["totalMinor"])

    if is_integer(qty) and is_integer(days) do
      "#{line["description"]}: #{qty} x #{days} x #{money(line["unitMinor"])} = #{amount}"
    else
      "#{line["description"]}: #{amount}"
    end
  end

  def money(minor) when is_integer(minor) do
    sign = if minor < 0, do: "−", else: ""
    abs = abs(minor)
    whole = div(abs, 100)
    fraction = abs |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}GHS #{group_thousands(Integer.to_string(whole))}.#{fraction}"
  end

  def money(_), do: "GHS 0.00"

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp email_html(invoice) do
    rows =
      invoice["lines"]
      |> List.wrap()
      |> Enum.map(fn line ->
        "<tr><td>#{escape(line["description"])}</td><td align=\"right\">#{escape(money(line["totalMinor"]))}</td></tr>"
      end)
      |> Enum.join()

    """
    <div style="font-family: sans-serif; color: #171e38;">
      <h1 style="color: #0c1654;">Instaclean invoice #{escape(invoice["invoiceNo"])}</h1>
      <p>#{escape(invoice["project"])} for #{escape(invoice["billToName"])}</p>
      <table style="width: 100%; border-collapse: collapse;">#{rows}</table>
      <p><strong>Total due: #{escape(money(invoice["totalMinor"]))}</strong></p>
      <p><a href="#{escape(invoice["viewUrl"])}">View your invoice</a></p>
      <p>InstacleanPro Ltd. · 148 West Legon Road, Gulf Estate, Accra</p>
    </div>
    """
  end

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp view_url(token) when is_binary(token) do
    base =
      Application.get_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")
      |> to_string()
      |> String.trim_trailing("/")

    "#{base}/invoices/#{token}"
  end

  defp view_url(_), do: nil

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp uuid_string(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.load!(value)
    end
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp(value) when is_binary(value), do: value

  defp map_rpc_error(%Postgrex.Error{postgres: %{message: message}} = error)
       when is_binary(message) do
    cond do
      String.contains?(message, "booking_not_found") -> {:error, :booking_not_found}
      String.contains?(message, "invalid_lines") -> {:error, :invalid_lines}
      String.contains?(message, "invalid_email") -> {:error, :invalid_email}
      String.contains?(message, "invalid_invoice") -> {:error, :invalid_invoice}
      String.contains?(message, "amount_too_large") -> {:error, :amount_too_large}
      String.contains?(message, "out of range") -> {:error, :amount_too_large}
      String.contains?(message, "recorded_by_not_authorized") -> {:error, :forbidden}
      String.contains?(message, "undefined_function") -> {:error, :database_unavailable}
      true -> database_error(error)
    end
  end

  defp map_rpc_error(error), do: database_error(error)

  defp database_error(error) do
    Logger.error("Direct admin invoice database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
