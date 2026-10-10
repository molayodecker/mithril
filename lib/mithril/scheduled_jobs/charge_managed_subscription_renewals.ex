defmodule Mithril.ScheduledJobs.ChargeManagedSubscriptionRenewals do
  @moduledoc false

  require Logger

  alias Mithril.BookingCustomerReminder.Schedule
  alias Mithril.Paystack.Transactions
  alias Mithril.Repo
  alias Mithril.Subscriptions.ManagedRenewal

  @batch_limit 25
  @charge_lead_days 7

  @spec run() :: :ok | {:error, term()}
  def run do
    unless paystack_configured?() do
      Logger.warning("charge_managed_subscription_renewals skipped missing Paystack config")
      return_ok()
    end

    today = Schedule.accra_date_string(System.system_time(:millisecond))
    charge_window_end = Schedule.add_days_to_date_string(today, @charge_lead_days)

    case load_due_subscriptions(charge_window_end) do
      {:ok, subscriptions} ->
        Enum.each(subscriptions, &process_subscription(&1, today, charge_window_end))
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp process_subscription(subscription, today, charge_window_end) do
    occurrence_date = subscription["next_occurrence_date"]

    occurrence_date =
      cond do
        is_nil(occurrence_date) ->
          nil

        to_string(occurrence_date) < today ->
          refresh_occurrence(subscription["id"], occurrence_date, today, charge_window_end)

        true ->
          to_string(occurrence_date)
      end

    if occurrence_date != nil do
      run_renewal(subscription, occurrence_date)
    end
  end

  defp run_renewal(subscription, occurrence_date) do
    subscription_id = subscription["id"]
    reference = ManagedRenewal.reference(subscription_id, occurrence_date)

    with {:ok, email} <- customer_email(subscription["customer_id"]),
         {:ok, amount_minor} <- amount_minor(subscription) do
      deps = %{
        authorization_code:
          String.trim(to_string(subscription["paystack_authorization_code"] || "")),
        email: email,
        amount_minor: amount_minor,
        currency: String.upcase(to_string(subscription["currency"] || "GHS")),
        reference: reference,
        claim_attempt: fn -> claim_attempt(subscription_id, occurrence_date, reference) end,
        update_attempt: fn patch -> update_attempt(subscription_id, occurrence_date, patch) end,
        verify_reference: &Transactions.verify_raw/1,
        charge_authorization: &Transactions.charge_authorization/1,
        find_booking: fn -> find_booking(subscription_id, occurrence_date, reference) end,
        insert_booking: fn charged_reference ->
          insert_booking(subscription, occurrence_date, amount_minor, charged_reference)
        end,
        mark_booking_paid: &mark_booking_paid(&1, subscription["cleaner_id"]),
        advance_recurrence: fn -> advance_recurrence(subscription_id) end
      }

      ManagedRenewal.run(deps)
    end
  end

  defp claim_attempt(subscription_id, occurrence_date, reference) do
    case Repo.query(
           """
           INSERT INTO public.subscription_renewal_attempts (
             subscription_id, occurrence_date, paystack_reference, status
           ) VALUES ($1::uuid, $2::date, $3, 'pending_charge')
           ON CONFLICT (subscription_id, occurrence_date) DO NOTHING
           RETURNING id, subscription_id, occurrence_date, paystack_reference, status, booking_id, last_error
           """,
           [subscription_id, occurrence_date, reference]
         ) do
      {:ok, %{rows: [row]}} ->
        row_to_attempt(row)

      _ ->
        case Repo.query(
               """
               SELECT id, subscription_id, occurrence_date, paystack_reference, status, booking_id, last_error
               FROM public.subscription_renewal_attempts
               WHERE subscription_id = $1::uuid AND occurrence_date = $2::date
               """,
               [subscription_id, occurrence_date]
             ) do
          {:ok, %{rows: [row]}} -> row_to_attempt(row)
          _ -> raise "claim_attempt_failed"
        end
    end
  end

  defp row_to_attempt([
         id,
         subscription_id,
         occurrence_date,
         paystack_reference,
         status,
         booking_id,
         last_error
       ]) do
    %{
      id: id,
      subscription_id: subscription_id,
      occurrence_date: occurrence_date,
      paystack_reference: paystack_reference,
      status: attempt_status(status),
      booking_id: booking_id,
      last_error: last_error
    }
  end

  defp attempt_status("paid"), do: :paid
  defp attempt_status("charged"), do: :charged
  defp attempt_status("paused"), do: :paused
  defp attempt_status("failed"), do: :failed
  defp attempt_status(_), do: :pending_charge

  defp update_attempt(subscription_id, occurrence_date, patch) do
    fields =
      patch
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)

    if fields != [] do
      {set_sql, params} = build_set_clause(fields, 3)

      Repo.query(
        """
        UPDATE public.subscription_renewal_attempts
        SET #{set_sql}, updated_at = now()
        WHERE subscription_id = $1::uuid AND occurrence_date = $2::date
        """,
        [subscription_id, occurrence_date | params]
      )
    end
  end

  defp build_set_clause(fields, start_index) do
    {parts, params, _} =
      Enum.reduce(fields, {[], [], start_index}, fn {column, value}, {parts, params, index} ->
        {parts ++ ["#{column} = $#{index}"], params ++ [value], index + 1}
      end)

    {Enum.join(parts, ", "), params}
  end

  defp find_booking(subscription_id, occurrence_date, reference) do
    case Repo.query(
           """
           SELECT id, payment_status FROM public.bookings
           WHERE subscription_id = $1::uuid AND scheduled_date = $2::date AND status <> 'cancelled'
           LIMIT 1
           """,
           [subscription_id, occurrence_date]
         ) do
      {:ok, %{rows: [[id, payment_status]]}} ->
        %{id: id, payment_status: to_string(payment_status || "")}

      _ ->
        case Repo.query(
               "SELECT id, payment_status FROM public.bookings WHERE reference = $1 LIMIT 1",
               [reference]
             ) do
          {:ok, %{rows: [[id, payment_status]]}} ->
            %{id: id, payment_status: to_string(payment_status || "")}

          _ ->
            nil
        end
    end
  end

  defp insert_booking(subscription, occurrence_date, amount_minor, charged_reference) do
    scheduled_time =
      case subscription["scheduled_time"] do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: "09:00:00", else: trimmed

        _ ->
          "09:00:00"
      end

    case Repo.query(
           """
           INSERT INTO public.bookings (
             customer_id, cleaner_id, direct_assigned_cleaner_id, service_id, title,
             scheduled_date, scheduled_time, duration_hours, address, location_coordinates,
             special_instructions, home_size, extra_task_ids, total_price, final_amount_minor,
             core_amount_minor, currency, subscription_id, status, payment_status, payment_method,
             reference, platform_fee, booking_cover, booking_cover_amount, pricing_version,
             timezone_name, supplies_option, supplies_allowance_minor, recurrence_interval, idempotency_key
           ) VALUES (
             $1::uuid, $2::uuid, $2::uuid, $3::integer, 'Regular Cleaning Service',
             $4::date, $5::time, COALESCE($6::numeric, 2), $7, $8::geometry,
             $9, $10, COALESCE($11::uuid[], '{}'), $12, $12, $12, $13, $14::uuid,
             CASE WHEN $2::uuid IS NULL THEN 'pending' ELSE 'confirmed' END,
             'pending', 'paystack', $15, 0, false, 0, COALESCE($16, 'v1'),
             'Africa/Accra', 'customer_provided', 0, $17, $15
           )
           RETURNING id
           """,
           [
             subscription["customer_id"],
             subscription["cleaner_id"],
             subscription["service_id"],
             occurrence_date,
             scheduled_time,
             subscription["duration_hours"],
             subscription["address"],
             subscription["location_coordinates"],
             subscription["special_instructions"],
             subscription["home_size"],
             subscription["extra_task_ids"],
             amount_minor,
             subscription["currency"] || "GHS",
             subscription["id"],
             charged_reference,
             subscription["pricing_version"],
             subscription["recurrence_interval"]
           ]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, %{id: id}}
      {:error, error} -> {:error, error.postgres.message}
    end
  end

  defp mark_booking_paid(booking_id, cleaner_id) do
    status = if is_nil(cleaner_id), do: "pending", else: "confirmed"

    case Repo.query(
           """
           UPDATE public.bookings
           SET payment_status = 'paid', status = $2, updated_at = now()
           WHERE id = $1::uuid
             AND status NOT IN ('cancelled', 'completed')
           RETURNING status
           """,
           [booking_id, status]
         ) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        case Repo.query("SELECT status FROM public.bookings WHERE id = $1::uuid", [booking_id]) do
          {:ok, %{rows: [[terminal_status]]}}
          when terminal_status in ["cancelled", "completed"] ->
            {:error, "booking_terminal_state:#{terminal_status}"}

          {:ok, %{rows: []}} ->
            {:error, "booking_not_found"}

          {:ok, _} ->
            {:error, "booking_state_changed"}

          {:error, error} ->
            {:error, error.postgres.message}
        end

      {:error, error} ->
        {:error, error.postgres.message}
    end
  end

  defp advance_recurrence(subscription_id) do
    case Repo.query("SELECT public.advance_subscription_recurrence_dates($1::uuid)", [
           subscription_id
         ]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error.postgres.message}
    end
  end

  defp refresh_occurrence(subscription_id, anchor_date, today, charge_window_end) do
    case Repo.query(
           "SELECT public.refresh_subscription_recurrence_dates($1::uuid, $2::date)",
           [subscription_id, anchor_date]
         ) do
      {:ok, %{rows: [[json]]}} when is_map(json) ->
        next = Map.get(json, "next_service_date") || Map.get(json, :next_service_date)

        if is_binary(next) and next >= today and next <= charge_window_end do
          next
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp load_due_subscriptions(charge_window_end) do
    Repo.query(
      """
      SELECT id, customer_id, cleaner_id, service_id, address, location_coordinates, duration_hours,
             recurrence_interval, amount, recurring_amount_minor, currency, scheduled_time,
             next_occurrence_date, paystack_authorization_code, special_instructions, home_size,
             extra_task_ids, pricing_version
      FROM public.subscriptions
      WHERE status = 'active'
        AND billing_mode = 'managed_authorization'
        AND paystack_authorization_code IS NOT NULL
        AND next_occurrence_date IS NOT NULL
        AND next_occurrence_date <= $1::date
      ORDER BY next_occurrence_date ASC
      LIMIT $2
      """,
      [charge_window_end, @batch_limit]
    )
    |> case do
      {:ok, %{columns: columns, rows: rows}} ->
        {:ok, Enum.map(rows, fn row -> Map.new(Enum.zip(columns, row)) end)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp customer_email(customer_id) do
    case Repo.query("SELECT email FROM public.users WHERE id = $1::uuid", [customer_id]) do
      {:ok, %{rows: [[email]]}} when is_binary(email) and email != "" -> {:ok, String.trim(email)}
      _ -> {:error, :missing_customer_email}
    end
  end

  defp amount_minor(subscription) do
    amount = subscription["recurring_amount_minor"] || subscription["amount"]

    case Integer.parse(to_string(amount)) do
      {minor, _} when minor > 0 -> {:ok, minor}
      _ -> {:error, :invalid_amount}
    end
  end

  defp paystack_configured?() do
    case Application.get_env(:mithril, :paystack_secret_key) do
      secret when is_binary(secret) and secret != "" -> true
      _ -> false
    end
  end

  defp return_ok, do: :ok
end
