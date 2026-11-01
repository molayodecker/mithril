defmodule Mithril.DirectContracts.Letter do
  @moduledoc """
  Wording for the client service agreement.

  Edit the clauses in this module. A letter that has already been sent keeps
  the words stored on that row.
  """

  alias Mithril.DirectContracts.Calendar

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def preview(contract, workers) do
    start = start_date(contract.created_at)
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
      "clauses" => clauses(long_date(start), fee)
    }
  end

  def worker_letter(contract, worker) do
    start = start_date(contract.created_at)
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

  def clauses(start_label, fee_label) do
    [
      clause(
        1,
        "Service",
        "Instaclean provides the workers named in this letter, in the roles stated, for service at the Client's premises. The engagement starts on #{start_label}."
      ),
      clause(
        2,
        "Workers",
        "The workers named in this letter attend under it. Instaclean may replace a worker after telling the Client. A worker stops attending on the end date Instaclean records. The monthly fee in clause 3 continues at the agreed amount until both parties change it in writing."
      ),
      clause(
        3,
        "Fee",
        "The Client pays Instaclean a monthly service fee of #{fee_label}. That amount is the full fee for the service in this letter for each month the letter is in force."
      ),
      clause(
        4,
        "Invoices",
        "Instaclean invoices each month. Payment is due within 7 days of the invoice date, in Ghana cedis, to the account stated on the invoice. The invoice may show one line for the service, or one line for each worker. Worker lines are shares of the same monthly fee and add up to it."
      ),
      clause(
        5,
        "Worker pay",
        "Instaclean pays the workers. Any advance Instaclean gives a worker is a matter between Instaclean and that worker. It leaves the Client's fee unchanged, and the Client does not repay it."
      ),
      clause(
        6,
        "A month already started",
        "The fee for a month is payable in full. Instaclean does not divide it by the days a worker attended. A different fee applies only from a month both parties have agreed in writing."
      ),
      clause(
        7,
        "Ending",
        "Either party may end this letter by written notice of 2 months. Service and the monthly fee continue through that notice. Instaclean confirms the end date in writing."
      ),
      clause(
        8,
        "After the letter ends",
        "For 6 months after the end date, the Client will not engage, hire, or pay a worker named in this letter, directly or through another person."
      ),
      clause(
        9,
        "The Client's premises",
        "The Client provides a safe place of work and tells the workers the rules of the premises. The workers follow those rules where they agree with this letter."
      ),
      clause(
        10,
        "Care and loss",
        "Instaclean selects and supplies the workers with reasonable care. Instaclean's liability for any one month is limited to the fee the Client paid for that month. This limit does not apply to death or personal injury caused by negligence, or to fraud."
      ),
      clause(
        11,
        "Law",
        "The laws of the Republic of Ghana govern this letter. The courts of Accra have jurisdiction."
      ),
      clause(
        12,
        "The whole agreement",
        "This letter and the invoices issued under it are the whole agreement for this service. A change takes effect when Instaclean records it and sends the Client an updated letter, or the next invoice that shows the change."
      )
    ]
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

  defp start_date(%DateTime{} = value), do: DateTime.to_date(value)
  defp start_date(%NaiveDateTime{} = value), do: NaiveDateTime.to_date(value)
  defp start_date(%Date{} = value), do: value

  defp long_date(%Date{} = date) do
    "#{date.day} #{Enum.at(@months, date.month - 1)} #{date.year}"
  end
end
