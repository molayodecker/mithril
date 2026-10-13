defmodule Mithril.DirectAdminBilling do
  @moduledoc "Custom invoices and payment advice stored without a booking."

  require Logger

  alias Mithril.Auth
  alias Mithril.DirectAdminActor
  alias Mithril.DirectAdminInvoices
  alias Mithril.Repo

  @max_minor 2_147_483_647
  @min_minor -2_147_483_648

  def list_invoices(user_id, page \\ 1) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, offset} <- page_offset(page) do
      query_rows(
        """
        SELECT id, form_type, invoice_no, issued_on::text, bill_to_name, bill_to_address,
               bill_to_phone, bill_to_email, project, lines, adjustment_minor, subtotal_minor,
               total_minor, currency, notes, updated_at
        FROM public.admin_billing_invoices
        ORDER BY updated_at DESC, id DESC
        LIMIT 50 OFFSET $1
        """,
        &present_invoice/1,
        [offset]
      )
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_invoice(user_id, invoice_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, id} <- dump_uuid(invoice_id),
         :ok <- require_admin(admin_uid),
         {:ok, payload} <- invoice_payload(params) do
      call_upsert("upsert_admin_billing_invoice", [id, admin_uid, payload])
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_advices(user_id, page \\ 1) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, offset} <- page_offset(page) do
      query_rows(
        """
        SELECT id, form_type, advice_no, pay_period, payment_date::text, paid_to_name,
               paid_to_address, paid_to_email, paid_to_phone, employee_id, role_name,
               department, pay_type, earnings, reimbursements, deductions, earnings_minor,
               reimbursements_minor, deductions_minor, net_minor, currency, pay_method,
               pay_account, pay_network, pay_reference, updated_at
        FROM public.admin_payment_advices
        ORDER BY updated_at DESC, id DESC
        LIMIT 50 OFFSET $1
        """,
        &present_advice/1,
        [offset]
      )
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_advice(user_id, advice_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, id} <- dump_uuid(advice_id),
         :ok <- require_admin(admin_uid),
         {:ok, payload} <- advice_payload(params) do
      call_upsert("upsert_admin_payment_advice", [id, admin_uid, payload])
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp page_offset(value) when is_integer(value) and value >= 1 and value <= 100_000,
    do: {:ok, (value - 1) * 50}

  defp page_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} -> page_offset(page)
      _ -> {:error, :invalid_request}
    end
  end

  defp page_offset(_), do: {:error, :invalid_request}

  defp call_upsert(function, [id, admin_uid, payload]) do
    case DirectAdminActor.with_actor(admin_uid, fn ->
           case Repo.query(
                  "SELECT public.#{function}($1::uuid, $2::uuid, $3::jsonb)",
                  [id, admin_uid, payload]
                ) do
             {:ok, %{rows: [[document]]}} when is_map(document) ->
               stringify_id(document)

             {:error, error} ->
               Repo.rollback(error)
           end
         end) do
      {:ok, document} -> {:ok, document}
      {:error, error} -> map_rpc_error(error)
    end
  end

  defp query_rows(sql, present, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, present)}
      {:error, error} -> map_rpc_error(error)
    end
  end

  defp invoice_payload(params) do
    with {:ok, form_type} <- form_type(params),
         {:ok, lines} <- invoice_lines(params["lines"] || params[:lines]),
         {:ok, adjustment} <- signed_amount(params["adjustmentMinor"] || params[:adjustmentMinor]),
         {:ok, issued_on} <- iso_date(params["issuedOn"] || params[:issuedOn]),
         {:ok, name} <- required_text(params["billToName"] || params[:billToName], 160),
         {:ok, project} <- required_text(params["project"] || params[:project], 160),
         {:ok, address} <- optional_text(params["billToAddress"] || params[:billToAddress], 500),
         {:ok, phone} <- optional_text(params["billToPhone"] || params[:billToPhone], 32),
         {:ok, email} <- optional_email(params["billToEmail"] || params[:billToEmail]),
         {:ok, notes} <- optional_text(params["notes"] || params[:notes], 2000),
         {:ok, invoice_no} <- optional_text(params["invoiceNo"] || params[:invoiceNo], 40) do
      {:ok,
       %{
         "formType" => form_type,
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

  defp advice_payload(params) do
    with {:ok, form_type} <- form_type(params),
         {:ok, earnings} <- money_lines(params["earnings"] || params[:earnings], true, false),
         {:ok, reimbursements} <-
           money_lines(params["reimbursements"] || params[:reimbursements], false, true),
         {:ok, deductions} <-
           money_lines(params["deductions"] || params[:deductions], false, false),
         {:ok, payment_date} <- iso_date(params["paymentDate"] || params[:paymentDate]),
         {:ok, name} <- required_text(params["paidToName"] || params[:paidToName], 160),
         {:ok, period} <- required_text(params["payPeriod"] || params[:payPeriod], 40),
         {:ok, address} <- optional_text(params["paidToAddress"] || params[:paidToAddress], 500),
         {:ok, phone} <- optional_text(params["paidToPhone"] || params[:paidToPhone], 32),
         {:ok, email} <- optional_email(params["paidToEmail"] || params[:paidToEmail]),
         {:ok, employee_id} <- optional_text(params["employeeId"] || params[:employeeId], 40),
         {:ok, role} <- optional_text(params["role"] || params[:role], 80),
         {:ok, department} <- optional_text(params["department"] || params[:department], 80),
         {:ok, pay_type} <- optional_text(params["payType"] || params[:payType], 80),
         {:ok, method} <- optional_text(params["payMethod"] || params[:payMethod], 80),
         {:ok, account} <- optional_text(params["payAccount"] || params[:payAccount], 40),
         {:ok, network} <- optional_text(params["payNetwork"] || params[:payNetwork], 40),
         {:ok, reference} <- optional_text(params["payReference"] || params[:payReference], 40),
         {:ok, advice_no} <- optional_text(params["adviceNo"] || params[:adviceNo], 40) do
      {:ok,
       %{
         "formType" => form_type,
         "adviceNo" => advice_no,
         "payPeriod" => period,
         "paymentDate" => payment_date,
         "paidToName" => name,
         "paidToAddress" => address,
         "paidToEmail" => email,
         "paidToPhone" => phone,
         "employeeId" => employee_id,
         "role" => role,
         "department" => department,
         "payType" => pay_type,
         "earnings" => earnings,
         "reimbursements" => reimbursements,
         "deductions" => deductions,
         "payMethod" => method,
         "payAccount" => account,
         "payNetwork" => network,
         "payReference" => reference
       }}
    end
  end

  defp invoice_lines(lines) when is_list(lines) and lines != [] and length(lines) <= 20 do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case invoice_line(line) do
        {:ok, encoded} -> {:cont, {:ok, acc ++ [encoded]}}
        :error -> {:halt, {:error, :invalid_lines}}
      end
    end)
  end

  defp invoice_lines(_), do: {:error, :invalid_lines}

  defp invoice_line(line) when is_map(line) do
    description = line["description"] || line[:description]
    unit = line["unitMinor"] || line[:unitMinor]
    qty = blank_count(line["qty"] || line[:qty])
    days = blank_count(line["days"] || line[:days])

    with {:ok, text} <- required_text(description, 200),
         true <- is_integer(unit) and unit > 0 and unit <= @max_minor,
         {:ok, _total} <- DirectAdminInvoices.line_total_minor(qty, days, unit) do
      {:ok, %{"description" => text, "qty" => qty, "days" => days, "unitMinor" => unit}}
    else
      _ -> :error
    end
  end

  defp invoice_line(_), do: :error

  defp money_lines(nil, false, _reference), do: {:ok, []}

  defp money_lines(lines, required, reference) when is_list(lines) and length(lines) <= 20 do
    filled =
      Enum.reject(lines, fn line ->
        is_map(line) and blank?(line["description"] || line[:description]) and
          blank?(line["amountMinor"] || line[:amountMinor]) and
          blank?(line["reference"] || line[:reference])
      end)

    cond do
      required and filled == [] ->
        {:error, :invalid_lines}

      true ->
        Enum.reduce_while(filled, {:ok, []}, fn line, {:ok, acc} ->
          case money_line(line, reference) do
            {:ok, encoded} -> {:cont, {:ok, acc ++ [encoded]}}
            :error -> {:halt, {:error, :invalid_lines}}
          end
        end)
    end
  end

  defp money_lines(_, _, _), do: {:error, :invalid_lines}

  defp money_line(line, reference) when is_map(line) do
    with {:ok, text} <- required_text(line["description"] || line[:description], 200),
         {:ok, minor} <- positive_amount(line["amountMinor"] || line[:amountMinor]),
         {:ok, ref} <- optional_text(line["reference"] || line[:reference], 40) do
      encoded = %{"description" => text, "amountMinor" => minor}
      {:ok, if(reference, do: Map.put(encoded, "reference", ref), else: encoded)}
    else
      _ -> :error
    end
  end

  defp money_line(_, _), do: :error

  defp form_type(params) do
    case params["formType"] || params[:formType] do
      form when form in ["w8ben", "1099"] -> {:ok, form}
      _ -> {:error, :invalid_form_type}
    end
  end

  defp present_invoice(row) do
    [
      id,
      form,
      number,
      issued,
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
      updated
    ] = row

    %{
      "id" => uuid_string(id),
      "formType" => form,
      "invoiceNo" => number,
      "issuedOn" => issued,
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
      "updatedAt" => timestamp(updated)
    }
  end

  defp present_advice(row) do
    [
      id,
      form,
      number,
      period,
      payment_date,
      name,
      address,
      email,
      phone,
      employee_id,
      role,
      department,
      pay_type,
      earnings,
      reimbursements,
      deductions,
      earnings_minor,
      reimbursements_minor,
      deductions_minor,
      net,
      currency,
      method,
      account,
      network,
      reference,
      updated
    ] = row

    %{
      "id" => uuid_string(id),
      "formType" => form,
      "adviceNo" => number,
      "payPeriod" => period,
      "paymentDate" => payment_date,
      "paidToName" => name,
      "paidToAddress" => address,
      "paidToEmail" => email,
      "paidToPhone" => phone,
      "employeeId" => employee_id,
      "role" => role,
      "department" => department,
      "payType" => pay_type,
      "earnings" => earnings || [],
      "reimbursements" => reimbursements || [],
      "deductions" => deductions || [],
      "earningsMinor" => earnings_minor,
      "reimbursementsMinor" => reimbursements_minor,
      "deductionsMinor" => deductions_minor,
      "netMinor" => net,
      "currency" => currency || "GHS",
      "payMethod" => method,
      "payAccount" => account,
      "payNetwork" => network,
      "payReference" => reference,
      "updatedAt" => timestamp(updated)
    }
  end

  defp stringify_id(document), do: Map.update(document, "id", nil, &uuid_string/1)

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

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp required_text(value, max) when is_binary(value) do
    text = String.trim(value)

    if text != "" and String.length(text) <= max,
      do: {:ok, text},
      else: {:error, :invalid_invoice}
  end

  defp required_text(_, _), do: {:error, :invalid_invoice}

  defp optional_text(nil, _max), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    text = String.trim(value)

    cond do
      text == "" -> {:ok, nil}
      String.length(text) <= max -> {:ok, text}
      true -> {:error, :invalid_invoice}
    end
  end

  defp optional_text(_, _), do: {:error, :invalid_invoice}

  defp optional_email(nil), do: {:ok, nil}
  defp optional_email(""), do: {:ok, nil}

  defp optional_email(value) when is_binary(value) do
    email = value |> String.trim() |> String.downcase()

    cond do
      email == "" -> {:ok, nil}
      String.length(email) > 200 -> {:error, :invalid_email}
      String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) -> {:ok, email}
      true -> {:error, :invalid_email}
    end
  end

  defp optional_email(_), do: {:error, :invalid_email}

  defp iso_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, :invalid_invoice}
    end
  end

  defp iso_date(_), do: {:error, :invalid_invoice}

  defp signed_amount(value)
       when is_integer(value) and value >= @min_minor and value <= @max_minor,
       do: {:ok, value}

  defp signed_amount(_), do: {:error, :invalid_invoice}

  defp positive_amount(value) when is_integer(value) and value > 0 and value <= @max_minor,
    do: {:ok, value}

  defp positive_amount(_), do: {:error, :invalid_lines}

  defp blank_count(nil), do: nil
  defp blank_count(value) when is_integer(value), do: value
  defp blank_count(_), do: :invalid

  defp map_rpc_error(%Postgrex.Error{postgres: %{message: message}} = error)
       when is_binary(message) do
    cond do
      String.contains?(message, "invalid_form_type") -> {:error, :invalid_form_type}
      String.contains?(message, "invalid_lines") -> {:error, :invalid_lines}
      String.contains?(message, "invalid_email") -> {:error, :invalid_email}
      String.contains?(message, "invalid_invoice") -> {:error, :invalid_invoice}
      String.contains?(message, "amount_too_large") -> {:error, :amount_too_large}
      String.contains?(message, "out of range") -> {:error, :amount_too_large}
      String.contains?(message, "recorded_by_not_authorized") -> {:error, :forbidden}
      String.contains?(message, "undefined_function") -> {:error, :database_unavailable}
      String.contains?(message, "undefined_table") -> {:error, :database_unavailable}
      true -> database_error(error)
    end
  end

  defp map_rpc_error(error), do: database_error(error)

  defp database_error(error) do
    Logger.error("Direct admin billing database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
