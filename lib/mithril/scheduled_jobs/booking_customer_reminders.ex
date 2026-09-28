defmodule Mithril.ScheduledJobs.BookingCustomerReminders do
  @moduledoc false

  alias Mithril.BookingCustomerReminder.{Config, Delivery, Schedule}
  alias Mithril.Repo

  @booking_columns ~w(id customer_id cleaner_id customer_contact_phone title scheduled_date scheduled_time address status payment_status schedule_group_id subscription_id recurrence_interval customer_reminder_7d_sent_at customer_reminder_7d_claimed_at customer_reminder_48h_sent_at customer_reminder_48h_claimed_at customer_reminder_sent_at cleaner_reminder_sent_at customer_reminder_claimed_at cleaner_reminder_claimed_at customer_reminder_morning_sent_at customer_reminder_morning_claimed_at)

  @pending_stamp_sql """
  (
    customer_reminder_7d_sent_at IS NULL OR
    customer_reminder_48h_sent_at IS NULL OR
    customer_reminder_sent_at IS NULL OR
    customer_reminder_morning_sent_at IS NULL OR
    (cleaner_id IS NOT NULL AND cleaner_reminder_sent_at IS NULL)
  )
  """

  @direct_origin_exclude """
  NOT EXISTS (
    SELECT 1 FROM public.direct_booking_origins o WHERE o.booking_id = bookings.id
  )
  """

  @spec run() :: :ok | {:error, term()}
  def run do
    config = Config.load()
    now_ms = System.system_time(:millisecond)
    today_accra = Schedule.accra_date_string(now_ms)
    look_ahead = Schedule.look_ahead_days(config.hours_7d, config.tolerance_hours)
    max_date = Schedule.add_days_to_date_string(today_accra, look_ahead)
    claim_ttl_ms = config.claim_ttl_minutes * 60_000

    with {:ok, paid_rows} <- fetch_paid_candidates(today_accra, max_date, config.batch_limit),
         {:ok, pending_rows} <-
           fetch_pending_candidates(today_accra, max_date, config.batch_limit),
         {:ok, open_groups} <- load_open_schedule_groups(pending_rows) do
      candidates =
        (paid_rows ++ pending_rows)
        |> Enum.filter(&Schedule.eligible_row?(&1, open_groups))
        |> Enum.uniq_by(& &1["id"])

      due_items =
        Schedule.select_due_work_items(candidates, now_ms, config.batch_limit, claim_ttl_ms,
          hours7d: config.hours_7d,
          hours48: config.hours_48,
          hours24: config.hours_24,
          tolerance_hours: config.tolerance_hours,
          morning_hour: config.morning_hour
        )

      contacts = load_contacts(due_items)

      Enum.each(due_items, fn %{row: row, stage: stage} ->
        process_due_item(row, stage, contacts, config, claim_ttl_ms)
      end)

      :ok
    else
      {:error, error} -> {:error, error}
    end
  end

  defp process_due_item(row, stage, contacts, config, claim_ttl_ms) do
    booking_id = row["id"]

    if claim_reminder(booking_id, stage, config.claim_ttl_minutes) do
      if stage == :cleaner do
        deliver_cleaner(row, contacts, stage, config)
      else
        deliver_customer(row, contacts, stage, config, claim_ttl_ms)
      end
    end
  end

  defp deliver_customer(row, contacts, stage, _config, _claim_ttl_ms) do
    customer = Map.get(contacts, row["customer_id"], default_contact("Customer"))

    delivery =
      Delivery.notify(row, customer, :customer, stage)

    if Schedule.notification_delivered?(delivery) do
      stamp_sent(row["id"], stage)
    else
      stamp_failure(
        row["id"],
        stage,
        "No customer channel delivered (#{Schedule.stage_label(stage)})"
      )
    end
  end

  defp deliver_cleaner(row, contacts, stage, _config) do
    cleaner = Map.get(contacts, row["cleaner_id"], default_contact("Cleaner"))
    customer = Map.get(contacts, row["customer_id"], default_contact("Customer"))

    delivery =
      Delivery.notify(row, cleaner, :cleaner, stage, customer_name: customer[:name])

    if Schedule.notification_delivered?(delivery) do
      stamp_sent(row["id"], stage)
    else
      stamp_failure(row["id"], stage, "No cleaner channel delivered")
    end
  end

  defp fetch_paid_candidates(min_date, max_date, batch_limit) do
    fetch_bookings(
      """
      SELECT #{column_sql()}
      FROM public.bookings
      WHERE #{@direct_origin_exclude}
        AND payment_status = 'paid'
        AND status IN ('confirmed', 'scheduled')
        AND #{@pending_stamp_sql}
        AND scheduled_date >= $1::date
        AND scheduled_date <= $2::date
      ORDER BY scheduled_date ASC, scheduled_time ASC
      LIMIT $3
      """,
      [min_date, max_date, batch_limit * 3]
    )
  end

  defp fetch_pending_candidates(min_date, max_date, batch_limit) do
    with {:ok, schedule_rows} <-
           fetch_bookings(
             """
             SELECT #{column_sql()}
             FROM public.bookings
             WHERE #{@direct_origin_exclude}
               AND payment_status IN ('pending', 'post_paid')
               AND status IN ('confirmed', 'scheduled')
               AND schedule_group_id IS NOT NULL
               AND #{@pending_stamp_sql}
               AND scheduled_date >= $1::date
               AND scheduled_date <= $2::date
             ORDER BY scheduled_date ASC, scheduled_time ASC
             LIMIT $3
             """,
             [min_date, max_date, batch_limit * 3]
           ),
         {:ok, subscription_rows} <-
           fetch_bookings(
             """
             SELECT #{column_sql()}
             FROM public.bookings
             WHERE #{@direct_origin_exclude}
               AND payment_status IN ('pending', 'post_paid')
               AND status IN ('pending', 'confirmed', 'scheduled')
               AND subscription_id IS NOT NULL
               AND #{@pending_stamp_sql}
               AND scheduled_date >= $1::date
               AND scheduled_date <= $2::date
             ORDER BY scheduled_date ASC, scheduled_time ASC
             LIMIT $3
             """,
             [min_date, max_date, batch_limit * 3]
           ) do
      {:ok, schedule_rows ++ subscription_rows}
    end
  end

  defp load_open_schedule_groups(rows) do
    group_ids =
      rows
      |> Enum.map(& &1["schedule_group_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if group_ids == [] do
      {:ok, MapSet.new()}
    else
      case Repo.query(
             """
             SELECT id::text FROM public.admin_booking_schedule_groups
             WHERE id = ANY($1::uuid[]) AND status = 'open'
             """,
             [group_ids]
           ) do
        {:ok, %{rows: rows}} -> {:ok, MapSet.new(Enum.map(rows, fn [id] -> id end))}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp load_contacts(due_items) do
    people_ids =
      due_items
      |> Enum.flat_map(fn %{row: row} -> [row["customer_id"], row["cleaner_id"]] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if people_ids == [] do
      %{}
    else
      users =
        case Repo.query(
               "SELECT id, email, phone FROM public.users WHERE id = ANY($1::uuid[])",
               [people_ids]
             ) do
          {:ok, %{rows: rows}} ->
            Map.new(rows, fn [id, email, phone] -> {id, %{email: email, phone: phone}} end)

          _ ->
            %{}
        end

      profiles =
        case Repo.query(
               """
               SELECT id, fullname, firstname, lastname
               FROM public.profiles WHERE id = ANY($1::uuid[])
               """,
               [people_ids]
             ) do
          {:ok, %{rows: rows}} ->
            Map.new(rows, fn [id, fullname, firstname, lastname] ->
              {id, %{fullname: fullname, firstname: firstname, lastname: lastname}}
            end)

          _ ->
            %{}
        end

      Map.new(people_ids, fn user_id ->
        user = Map.get(users, user_id, %{email: nil, phone: nil})
        profile = Map.get(profiles, user_id, %{})

        composed =
          [profile[:firstname], profile[:lastname]]
          |> Enum.map(&((&1 || "") |> to_string() |> String.trim()))
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" ")

        name =
          [profile[:fullname], composed]
          |> Enum.map(&((&1 || "") |> to_string() |> String.trim()))
          |> Enum.reject(&(&1 == ""))
          |> List.first() || "Customer"

        {user_id,
         %{
           user_id: user_id,
           email: user[:email],
           phone: user[:phone],
           name: name
         }}
      end)
    end
  end

  defp default_contact(label) do
    %{user_id: nil, email: nil, phone: nil, name: label}
  end

  defp claim_reminder(booking_id, stage, claim_ttl_minutes) do
    kind = Schedule.claim_kind(stage)

    case Repo.query(
           "SELECT public.claim_booking_reminder($1::uuid, $2, $3)",
           [booking_id, kind, claim_ttl_minutes]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp stamp_sent(booking_id, stage) do
    {patch_sql, null_col} = sent_patch(stage)

    Repo.query(
      "UPDATE public.bookings SET #{patch_sql} WHERE id = $1::uuid AND #{null_col} IS NULL",
      [booking_id]
    )
  end

  defp stamp_failure(booking_id, stage, message) do
    trimmed = String.slice(message, 0, 500)

    if stage == :cleaner do
      Repo.query(
        """
        UPDATE public.bookings
        SET cleaner_reminder_last_error = $2, cleaner_reminder_claimed_at = NULL
        WHERE id = $1::uuid
        """,
        [booking_id, trimmed]
      )
    else
      Repo.query(
        """
        UPDATE public.bookings
        SET customer_reminder_last_error = $2, #{claimed_null_sql(stage)}
        WHERE id = $1::uuid
        """,
        [booking_id, trimmed]
      )
    end
  end

  defp sent_patch(:customer_7d) do
    {"customer_reminder_7d_sent_at = now(), customer_reminder_7d_claimed_at = NULL, customer_reminder_last_error = NULL",
     "customer_reminder_7d_sent_at"}
  end

  defp sent_patch(:customer_48h) do
    {"customer_reminder_48h_sent_at = now(), customer_reminder_48h_claimed_at = NULL, customer_reminder_last_error = NULL",
     "customer_reminder_48h_sent_at"}
  end

  defp sent_patch(:customer_morning) do
    {"customer_reminder_morning_sent_at = now(), customer_reminder_morning_claimed_at = NULL, customer_reminder_last_error = NULL",
     "customer_reminder_morning_sent_at"}
  end

  defp sent_patch(:cleaner) do
    {"cleaner_reminder_sent_at = now(), cleaner_reminder_claimed_at = NULL, cleaner_reminder_last_error = NULL",
     "cleaner_reminder_sent_at"}
  end

  defp sent_patch(_) do
    {"customer_reminder_sent_at = now(), customer_reminder_claimed_at = NULL, customer_reminder_last_error = NULL",
     "customer_reminder_sent_at"}
  end

  defp claimed_null_sql(:customer_7d), do: "customer_reminder_7d_claimed_at = NULL"
  defp claimed_null_sql(:customer_48h), do: "customer_reminder_48h_claimed_at = NULL"
  defp claimed_null_sql(:customer_morning), do: "customer_reminder_morning_claimed_at = NULL"
  defp claimed_null_sql(_), do: "customer_reminder_claimed_at = NULL"

  defp fetch_bookings(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row_to_map/1)}
      {:error, error} -> {:error, error}
    end
  end

  defp row_to_map(row), do: Map.new(Enum.zip(@booking_columns, row))
  defp column_sql, do: Enum.join(@booking_columns, ", ")
end
