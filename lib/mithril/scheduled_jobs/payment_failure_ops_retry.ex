defmodule Mithril.ScheduledJobs.PaymentFailureOpsRetry do
  @moduledoc false

  require Logger

  alias Mithril.Repo
  alias Mithril.SupportOps

  @retry_max_attempts 5
  @batch_limit 25

  @allowed_sources ~w(paystack_charge_failed posthog_payment_failed mobile_checkout_failed)

  @spec run() :: :ok | {:error, term()}
  def run do
    admin_url = admin_bookings_url()

    case load_due_rows() do
      {:ok, rows} ->
        {attempted, sent, failed} = Enum.reduce(rows, {0, 0, 0}, &retry_row(&1, admin_url, &2))

        Logger.info(
          "payment_failure_ops_retry attempted=#{attempted} sent=#{sent} failed=#{failed}"
        )

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_due_rows do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query(
      """
      SELECT id, source, customer_id, booking_id, subscription_id, paystack_reference,
             reason, action, gateway_response, amount_label, platform, transport_failure,
             slack_status, slack_attempt_count
      FROM public.payment_failure_ops_alerts
      WHERE slack_status IN ('pending', 'failed')
        AND slack_attempt_count < $1
        AND next_retry_at <= $2::timestamptz
      ORDER BY next_retry_at ASC
      LIMIT $3
      """,
      [@retry_max_attempts, now, @batch_limit]
    )
    |> case do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn row ->
           columns =
             ~w(id source customer_id booking_id subscription_id paystack_reference reason action gateway_response amount_label platform transport_failure slack_status slack_attempt_count)

           Map.new(Enum.zip(columns, row))
         end)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp retry_row(row, admin_url, {attempted, sent, failed}) do
    source = row["source"] |> to_string()

    if source in @allowed_sources do
      attempted = attempted + 1

      case deliver_slack(row, admin_url) do
        true ->
          update_status(row, true)
          {attempted, sent + 1, failed}

        false ->
          update_status(row, false)
          {attempted, sent, failed + 1}
      end
    else
      {attempted, sent, failed + 1}
    end
  end

  defp deliver_slack(row, admin_url) do
    body = build_body(row, admin_url)
    SupportOps.send_slack(body)
  end

  defp build_body(row, admin_url) do
    lines = ["A customer payment attempt failed.", "", "Source: #{row["source"]}"]

    lines =
      lines
      |> maybe_line("Booking ID", row["booking_id"])
      |> maybe_line("Subscription ID", row["subscription_id"])
      |> maybe_line("Paystack reference", row["paystack_reference"])
      |> maybe_line("Reason", row["reason"])
      |> maybe_line("Action", row["action"])
      |> maybe_line("Gateway response", row["gateway_response"])
      |> maybe_line("Amount", row["amount_label"])
      |> maybe_line("Platform", row["platform"])

    lines =
      if row["transport_failure"] == true do
        lines ++ ["Transport failure: yes"]
      else
        lines
      end

    (lines ++ ["", "Admin: #{admin_url}"]) |> Enum.join("\n")
  end

  defp maybe_line(lines, _label, nil), do: lines
  defp maybe_line(lines, _label, ""), do: lines

  defp maybe_line(lines, label, value) do
    lines ++ ["#{label}: #{value}"]
  end

  defp update_status(row, slack_sent) do
    attempt_count = (row["slack_attempt_count"] || 0) + 1

    {status, next_retry_at, sent_at, last_error} =
      if slack_sent do
        {"sent", nil, DateTime.utc_now(), nil}
      else
        delay_ms = retry_delay_ms(attempt_count)
        next_at = DateTime.utc_now() |> DateTime.add(delay_ms, :millisecond)
        {"failed", next_at, nil, "slack_delivery_failed"}
      end

    Repo.query!(
      """
      UPDATE public.payment_failure_ops_alerts
      SET slack_status = $2,
          slack_attempt_count = $3,
          slack_last_error = $4,
          slack_sent_at = $5,
          next_retry_at = $6,
          updated_at = now()
      WHERE id = $1::uuid
      """,
      [row["id"], status, attempt_count, last_error, sent_at, next_retry_at]
    )
  end

  defp retry_delay_ms(attempt_count) do
    safe = max(1, attempt_count)
    multiplier = :math.pow(2, max(0, safe - 1))
    min(trunc(5 * 60 * 1000 * multiplier), 60 * 60 * 1000)
  end

  defp admin_bookings_url do
    base =
      Application.get_env(:mithril, :app_url, "https://tryinstaclean.com")
      |> to_string()
      |> String.trim_trailing("/")

    base <> "/admin/bookings"
  end
end
