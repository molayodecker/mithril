defmodule Mithril.DirectContracts.Letter do
  @moduledoc """
  Wording for the client service agreement.

  Edit the clauses in this module. A letter that has already been sent keeps
  the words stored on that row.
  """

  alias Mithril.DirectContracts.Calendar

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def preview(contract, workers) do
    start = engagement_date(contract)
    fee = Calendar.format_ghs(contract.monthly_fee_minor)

    %{
      "letterNo" => nil,
      "issuedOn" => Date.to_iso8601(Calendar.today()),
      "startOn" => Date.to_iso8601(start),
      "monthlyFeeMinor" => contract.monthly_fee_minor,
      "currency" => contract.currency || "GHS",
      "clientName" => contract.name,
      "billingContact" => contract.billing_contact,
      "phone" => contract.phone,
      "email" => contract.email,
      "preamble" => preamble(contract.name),
      "workers" =>
        Enum.map(workers, fn worker ->
          %{"roleLabel" => worker.role_label, "workerName" => worker.worker_name}
        end),
      "clauses" =>
        clauses(long_date(start), fee, include_invoices?(contract), letter_note(contract))
    }
    |> apply_saved_wording(Map.get(contract, :letter_content))
  end

  def worker_letter(contract, worker) do
    start = start_date(worker.started_at)
    advance = worker.weekly_advance_minor || 0

    %{
      "workerName" => worker.worker_name,
      "roleLabel" => worker.role_label,
      "clientName" => contract.name,
      "phone" => worker.phone,
      "email" => worker.email,
      "monthlyPayMinor" => worker.monthly_pay_minor,
      "weeklyAdvanceMinor" => advance,
      "currency" => contract.currency || "GHS",
      "startOn" => Date.to_iso8601(start),
      "preamble" => worker_preamble(worker.worker_name),
      "clauses" =>
        worker_clauses(
          long_date(start),
          worker.role_label,
          contract.name,
          Calendar.format_ghs(worker.monthly_pay_minor),
          advance
        )
    }
  end

  def preamble(client_name) do
    "This letter is between InstacleanPro Limited (\"Instaclean\"), of 148 West Legon Road, Gulf Estate, Accra, and #{client_name} (\"the Client\")."
  end

  def clauses(start_label, fee_label, include_invoices \\ true, letter_note \\ nil) do
    [
      {"Service",
       "Instaclean provides the workers named in this letter, in the roles stated, for service at the Client's premises. The engagement starts on #{start_label}."},
      {"Workers",
       "The workers named in this letter attend under it. Instaclean may replace a worker after telling the Client. A worker stops attending on the end date Instaclean records. The monthly fee in clause 3 continues at the agreed amount until both parties change it in writing."},
      {"Fee",
       "The Client pays Instaclean a monthly service fee of #{fee_label}. That amount is the full fee for the service in this letter for each month the letter is in force."}
    ]
    |> then(fn items ->
      if include_invoices do
        items ++ [invoice_item()]
      else
        items
      end
    end)
    |> Kernel.++([
      {"Worker pay",
       "Instaclean pays the workers. Any advance Instaclean gives a worker is a matter between Instaclean and that worker. It leaves the Client's fee unchanged, and the Client does not repay it."},
      {"A month already started",
       "The fee for a month is payable in full. Instaclean does not divide it by the days a worker attended. A different fee applies only from a month both parties have agreed in writing."},
      {"Ending",
       "Either party may end this letter by written notice of 2 months. Service and the monthly fee continue through that notice. Instaclean confirms the end date in writing."},
      {"After the letter ends",
       "For 6 months after the end date, the Client will not engage, hire, or pay a worker named in this letter, directly or through another person."},
      {"The Client's premises",
       "The Client provides a safe place of work and tells the workers the rules of the premises. The workers follow those rules where they agree with this letter."},
      {"Care and loss",
       "Instaclean selects and supplies the workers with reasonable care. Instaclean's liability for any loss or damage is limited to one month's fees paid by the Client. This limit does not apply to death or personal injury caused by negligence, or to fraud."},
      {"Law",
       "The laws of the Republic of Ghana govern this letter. The courts of Accra have jurisdiction."}
    ])
    |> Kernel.++(note_items(letter_note))
    |> Kernel.++([{"The whole agreement", whole_agreement(include_invoices)}])
    |> Enum.with_index(1)
    |> Enum.map(fn {{title, body}, number} -> clause(number, title, body) end)
  end

  defp invoice_item do
    {"Invoices",
     "Instaclean invoices each month. Payment is due within 7 days of the invoice date, in Ghana cedis, to the account stated on the invoice. The invoice may show one line for the service, or one line for each worker. Worker lines are shares of the same monthly fee and add up to it."}
  end

  defp whole_agreement(true) do
    "This letter and the invoices issued under it are the whole agreement for this service. A change takes effect when Instaclean records it and sends the Client an updated letter, or the next invoice that shows the change."
  end

  defp whole_agreement(false) do
    "This letter is the whole agreement for this service. A change takes effect when Instaclean records it and sends the Client an updated letter."
  end

  defp include_invoices?(%{include_invoices: false}), do: false
  defp include_invoices?(_), do: true

  defp letter_note(%{letter_note: note}) when is_binary(note), do: note
  defp letter_note(_), do: nil

  # One sentence an operator added for this contract. It sits before the
  # whole-agreement clause so it is part of the letter the client signs.
  defp note_items(note) when is_binary(note) do
    case note |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> []
      text -> [{"Additional term", text}]
    end
  end

  defp note_items(_), do: []

  def apply_saved_wording(preview, content) do
    case stored_wording(content) do
      nil ->
        Map.put(preview, "customWording", false)

      wording ->
        preview
        |> Map.put("preamble", wording["preamble"])
        |> Map.put("clauses", number_clauses(wording["clauses"]))
        |> Map.put("customWording", true)
    end
  end

  # Keep an edited letter and the extra sentence in agreement when either one changes.
  def resolve_wording(current_note, current_content, note_action, content_action) do
    content =
      case content_action do
        :keep -> stored_wording(current_content)
        {:set, nil} -> nil
        {:set, wording} -> wording
      end

    note =
      case note_action do
        :keep -> squish_note(current_note)
        {:set, value} -> squish_note(value)
      end

    cond do
      content_action != :keep and is_map(content) ->
        {additional_note(content), content}

      content_action == {:set, nil} ->
        {note, nil}

      is_map(content) and note_action != :keep ->
        case replace_additional_term(content, note) do
          {:ok, updated} -> {note, updated}
          :empty -> {nil, nil}
        end

      true ->
        {note, content}
    end
  end

  def stored_wording(nil), do: nil

  def stored_wording(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> stored_wording(decoded)
      _ -> nil
    end
  end

  def stored_wording(value) when is_map(value) do
    case normalize_wording(value) do
      {:ok, wording} ->
        %{
          "preamble" => wording.preamble,
          "clauses" => Enum.map(wording.clauses, &Map.take(&1, ["title", "body"]))
        }

      :error ->
        nil
    end
  end

  def stored_wording(_), do: nil

  def normalize_wording(%{"preamble" => preamble, "clauses" => clauses})
      when is_binary(preamble) and is_list(clauses) do
    with {:ok, preamble} <- wording_text(preamble, 4_000),
         {:ok, clauses} <- wording_clauses(clauses) do
      {:ok, %{preamble: preamble, clauses: clauses}}
    else
      _ -> :error
    end
  end

  def normalize_wording(%{preamble: preamble, clauses: clauses}) do
    normalize_wording(%{"preamble" => preamble, "clauses" => clauses})
  end

  def normalize_wording(_), do: :error

  def replace_additional_term(%{"clauses" => clauses} = content, note) when is_list(clauses) do
    next =
      clauses
      |> Enum.map(&clause_fields/1)
      |> Enum.reject(&is_nil/1)
      |> put_term(squish_note(note))

    if next == [] do
      :empty
    else
      {:ok, %{content | "clauses" => next}}
    end
  end

  def replace_additional_term(_, _), do: :empty

  defp additional_note(%{"clauses" => clauses}) when is_list(clauses) do
    Enum.find_value(clauses, fn clause ->
      case clause_fields(clause) do
        %{"title" => "Additional term", "body" => body} -> body
        _ -> nil
      end
    end)
  end

  defp additional_note(_), do: nil

  defp put_term(clauses, nil) do
    Enum.reject(clauses, &(&1["title"] == "Additional term"))
  end

  defp put_term(clauses, text) do
    without = Enum.reject(clauses, &(&1["title"] == "Additional term"))
    item = %{"title" => "Additional term", "body" => text}

    case Enum.find_index(without, &(&1["title"] == "The whole agreement")) do
      nil -> without ++ [item]
      index -> List.insert_at(without, index, item)
    end
  end

  defp wording_clauses(clauses) when length(clauses) in 1..24 do
    clauses
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, acc} ->
      case wording_clause(clause) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, number_clauses(Enum.reverse(items))}
      :error -> :error
    end
  end

  defp wording_clauses(_), do: :error

  defp wording_clause(clause) do
    case clause_fields(clause) do
      %{"title" => title, "body" => body} ->
        with {:ok, title} <- wording_text(title, 120),
             {:ok, body} <- wording_text(body, 4_000) do
          {:ok, %{"title" => title, "body" => body}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp clause_fields(%{"title" => title, "body" => body})
       when is_binary(title) and is_binary(body) do
    %{"title" => title, "body" => body}
  end

  defp clause_fields(%{title: title, body: body}) when is_binary(title) and is_binary(body) do
    %{"title" => title, "body" => body}
  end

  defp clause_fields(_), do: nil

  defp wording_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> :error
      String.length(trimmed) > max -> :error
      true -> {:ok, trimmed}
    end
  end

  defp squish_note(nil), do: nil

  defp squish_note(value) when is_binary(value) do
    case value |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp squish_note(_), do: nil

  defp number_clauses(clauses) do
    clauses
    |> Enum.with_index(1)
    |> Enum.map(fn {clause, number} -> Map.put(clause, "number", number) end)
  end

  def worker_preamble(worker_name) do
    "This letter is between InstacleanPro Limited (\"Instaclean\"), of 148 West Legon Road, Gulf Estate, Accra, and #{worker_name} (\"the Worker\")."
  end

  def worker_clauses(start_label, role, client_name, pay_label, advance_minor) do
    advance_label = Calendar.format_ghs(advance_minor)

    [
      clause(
        1,
        "The work",
        "The Worker attends as #{role} for #{client_name}. The engagement starts on #{start_label}."
      ),
      clause(
        2,
        "Pay",
        "Instaclean pays the Worker #{pay_label} for each month this assignment is in force. Instaclean does not divide that pay by the days the Worker attended."
      ),
      clause(3, "Weekly advance", advance_clause(advance_minor, advance_label)),
      clause(
        4,
        "Ending",
        "Instaclean records the date this assignment ends. Pay for a month already started stays the full monthly amount. Advances already paid are deducted. No further advance is paid after that date."
      ),
      clause(
        5,
        "After the assignment ends",
        "For 6 months after the end date, the Worker will not work for #{client_name} directly, or through another person, without Instaclean's written agreement."
      ),
      clause(
        6,
        "Law",
        "The laws of the Republic of Ghana govern this letter. The courts of Accra have jurisdiction."
      ),
      clause(
        7,
        "The whole agreement",
        "This letter is the agreement for the Worker's pay on this assignment. The Client's service agreement is a separate letter and does not set the Worker's pay."
      )
    ]
  end

  defp advance_clause(0, _label) do
    "This assignment has no weekly advance. Instaclean pays the monthly amount on payday."
  end

  defp advance_clause(_minor, label) do
    "Instaclean may pay the Worker a weekly advance of #{label} into the Worker's Instaclean wallet. An advance already paid is deducted from that month's pay. The advance does not change the fee the Client pays Instaclean."
  end

  defp clause(number, title, body) do
    %{"number" => number, "title" => title, "body" => body}
  end

  defp engagement_date(%{start_on: %Date{} = date}), do: date
  defp engagement_date(%{created_at: created}), do: start_date(created)

  defp start_date(%DateTime{} = value), do: DateTime.to_date(value)
  defp start_date(%NaiveDateTime{} = value), do: NaiveDateTime.to_date(value)
  defp start_date(%Date{} = value), do: value

  defp long_date(%Date{} = date) do
    "#{date.day} #{Enum.at(@months, date.month - 1)} #{date.year}"
  end
end
