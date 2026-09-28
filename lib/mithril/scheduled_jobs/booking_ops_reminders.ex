defmodule Mithril.ScheduledJobs.BookingOpsReminders do
  @moduledoc false

  alias Mithril.BookingOps.UnassignedWaiting
  alias Mithril.Repo
  alias Mithril.SupportOps

  @batch_limit 40
  @scan_page 40
  @scan_max 400
  @confirmed_hours 24
  @unassigned_minutes 60

  @booking_columns ~w(id customer_id cleaner_id title scheduled_date scheduled_time address status payment_status total_price final_amount_minor created_at updated_at assignment_phase assignment_hold_until dispatch_gated_at dispatch_gate_cleared_at assignment_escalated_at ops_assignment_escalation_notice_sent_at ops_unassigned_paid_notice_sent_at)

  @spec run() :: :ok | {:error, term()}
  def run do
    admin_url = admin_bookings_url()

    with :ok <- process_new_bookings(admin_url),
         :ok <- process_confirmed_reminders(admin_url),
         :ok <- process_unassigned_paid(admin_url),
         :ok <- process_assignment_escalations(admin_url) do
      :ok
    end
  end

  defp process_new_bookings(admin_url) do
    case fetch_bookings(
           """
           SELECT #{column_sql()}
           FROM public.bookings
           WHERE ops_new_booking_notice_sent_at IS NULL
           ORDER BY created_at ASC
           LIMIT $1
           """,
           [@batch_limit]
         ) do
      {:ok, rows} ->
        contacts = load_contacts(rows)

        Enum.each(rows, fn row ->
          if claim_notice(row["id"], "ops_new_booking_notice_sent_at") do
            body = new_booking_body(row, contacts, admin_url)

            if deliver_ops("[Instaclean] New booking", body) do
              :ok
            else
              release_notice(row["id"], "ops_new_booking_notice_sent_at")
            end
          end
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp process_confirmed_reminders(admin_url) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@confirmed_hours * 3600, :second)
      |> DateTime.to_iso8601()

    case fetch_bookings(
           """
           SELECT #{column_sql()}
           FROM public.bookings
           WHERE status = 'confirmed'
             AND payment_status = 'paid'
             AND ops_confirmed_reminder_sent_at IS NULL
             AND created_at <= $1::timestamptz
           ORDER BY created_at ASC
           LIMIT $2
           """,
           [cutoff, @batch_limit]
         ) do
      {:ok, rows} ->
        contacts = load_contacts(rows)

        Enum.each(rows, fn row ->
          if claim_notice(row["id"], "ops_confirmed_reminder_sent_at") do
            body = confirmed_body(row, contacts, admin_url)

            if deliver_ops("[Instaclean] Confirmed booking still open", body) do
              :ok
            else
              release_notice(row["id"], "ops_confirmed_reminder_sent_at")
            end
          end
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp process_unassigned_paid(admin_url) do
    due_rows = load_due_unassigned_rows()

    contacts = load_contacts(due_rows)

    Enum.each(due_rows, fn row ->
      repeat? = UnassignedWaiting.repeat_notice?(row)
      body = unassigned_body(row, contacts, admin_url, repeat?)

      if SupportOps.delivered?(
           SupportOps.notify(%{subject: unassigned_subject(repeat?), plain_body: body})
         ) do
        mark_unassigned_sent(row["id"])
      end
    end)

    :ok
  end

  defp process_assignment_escalations(admin_url) do
    case fetch_bookings(
           """
           SELECT #{column_sql()}
           FROM public.bookings
           WHERE assignment_escalated_at IS NOT NULL
             AND ops_assignment_escalation_notice_sent_at IS NULL
           ORDER BY assignment_escalated_at ASC
           LIMIT $1
           """,
           [@batch_limit]
         ) do
      {:ok, rows} ->
        contacts = load_contacts(rows)

        Enum.each(rows, fn row ->
          if claim_notice(row["id"], "ops_assignment_escalation_notice_sent_at") do
            body = escalation_body(row, contacts, admin_url)

            if deliver_ops("[Instaclean] Assignment escalated — ops action needed", body) do
              :ok
            else
              release_notice(row["id"], "ops_assignment_escalation_notice_sent_at")
            end
          end
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_due_unassigned_rows do
    do_scan(0, [])
  end

  defp do_scan(_offset, due_rows) when length(due_rows) >= @batch_limit,
    do: Enum.take(due_rows, @batch_limit)

  defp do_scan(offset, due_rows) when offset >= @scan_max, do: due_rows

  defp do_scan(offset, due_rows) do
    case fetch_bookings(
           """
           SELECT #{column_sql()}
           FROM public.bookings
           WHERE payment_status = 'paid'
             AND cleaner_id IS NULL
             AND cleaner_accepted_at IS NULL
             AND assignment_escalated_at IS NULL
             AND ops_unassigned_paid_reminders_stopped_at IS NULL
             AND status IN ('pending', 'confirmed', 'scheduled')
           ORDER BY updated_at ASC
           OFFSET $1 LIMIT $2
           """,
           [offset, @scan_page]
         ) do
      {:ok, []} ->
        sort_unassigned(due_rows)

      {:ok, page} ->
        page_due =
          Enum.filter(page, fn row ->
            UnassignedWaiting.notice_due?(row, @unassigned_minutes)
          end)

        next_due = due_rows ++ page_due

        if length(page) < @scan_page do
          sort_unassigned(next_due)
        else
          do_scan(offset + @scan_page, next_due)
        end

      {:error, _error} ->
        sort_unassigned(due_rows)
    end
  end

  defp sort_unassigned(rows) do
    rows
    |> Enum.sort_by(&UnassignedWaiting.sort_key_ms/1)
    |> Enum.take(@batch_limit)
  end

  defp fetch_bookings(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_map/1)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp row_to_map(row) do
    Map.new(Enum.zip(@booking_columns, row))
  end

  defp column_sql, do: Enum.join(@booking_columns, ", ")

  defp load_contacts(rows) do
    customer_ids =
      rows
      |> Enum.map(& &1["customer_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if customer_ids == [] do
      %{}
    else
      case Repo.query(
             """
             SELECT u.id, u.email, u.phone,
                    COALESCE(NULLIF(btrim(p.fullname), ''), NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''), 'Customer')
             FROM public.users u
             LEFT JOIN public.profiles p ON p.id = u.id
             WHERE u.id = ANY($1::uuid[])
             """,
             [customer_ids]
           ) do
        {:ok, %{rows: user_rows}} ->
          Map.new(user_rows, fn [id, email, phone, name] ->
            {id, %{email: email, phone: phone, name: name}}
          end)

        _ ->
          %{}
      end
    end
  end

  defp customer_name(row, contacts) do
    Map.get(contacts, row["customer_id"], %{name: "Customer"})[:name] || "Customer"
  end

  defp customer_email(row, contacts) do
    Map.get(contacts, row["customer_id"], %{email: nil})[:email] || "(none)"
  end

  defp new_booking_body(row, contacts, admin_url) do
    """
    A new booking was created.

    Booking ID: #{row["id"]}
    Service: #{row["title"] || ""}
    Customer: #{customer_name(row, contacts)}
    Email: #{customer_email(row, contacts)}
    Schedule: #{row["scheduled_date"]} #{row["scheduled_time"]}
    Address: #{row["address"] || ""}
    Status: #{row["status"]}
    Payment: #{row["payment_status"]}

    Admin: #{admin_url}
    """
    |> String.trim()
  end

  defp confirmed_body(row, contacts, admin_url) do
    """
    This paid booking has stayed confirmed for at least #{@confirmed_hours} hours.

    Booking ID: #{row["id"]}
    Customer: #{customer_name(row, contacts)}
    Schedule: #{row["scheduled_date"]} #{row["scheduled_time"]}
    Status: #{row["status"]}

    Admin: #{admin_url}
    """
    |> String.trim()
  end

  defp unassigned_body(row, contacts, admin_url, repeat?) do
    prefix =
      if repeat? do
        "Repeat alert: this paid booking is still unassigned."
      else
        "This paid booking is still unassigned after at least #{@unassigned_minutes} minutes."
      end

    """
    #{prefix} Ops may need to assign manually or follow up with cleaners.

    Booking ID: #{row["id"]}
    Service: #{row["title"] || ""}
    Customer: #{customer_name(row, contacts)}
    Email: #{customer_email(row, contacts)}
    Schedule: #{row["scheduled_date"]} #{row["scheduled_time"]}
    Address: #{row["address"] || ""}
    Status: #{row["status"]}
    Payment: #{row["payment_status"]}
    Assignment phase: #{row["assignment_phase"] || ""}

    Admin: #{admin_url}
    """
    |> String.trim()
  end

  defp escalation_body(row, contacts, admin_url) do
    """
    Paid booking assignment was escalated (broadcast grace ended with no cleaner).

    Booking ID: #{row["id"]}
    Customer: #{customer_name(row, contacts)}
    Schedule: #{row["scheduled_date"]} #{row["scheduled_time"]}

    Admin: #{admin_url}
    """
    |> String.trim()
  end

  defp unassigned_subject(repeat?) do
    if repeat? do
      "[Instaclean] Repeat: unassigned paid booking"
    else
      "[Instaclean] Unassigned paid booking"
    end
  end

  defp deliver_ops(subject, plain_body) do
    SupportOps.delivered?(SupportOps.notify(%{subject: subject, plain_body: plain_body}))
  end

  @notice_columns %{
    "ops_new_booking_notice_sent_at" =>
      "UPDATE public.bookings SET ops_new_booking_notice_sent_at = now() WHERE id = $1::uuid AND ops_new_booking_notice_sent_at IS NULL RETURNING id",
    "ops_confirmed_reminder_sent_at" =>
      "UPDATE public.bookings SET ops_confirmed_reminder_sent_at = now() WHERE id = $1::uuid AND ops_confirmed_reminder_sent_at IS NULL RETURNING id",
    "ops_assignment_escalation_notice_sent_at" =>
      "UPDATE public.bookings SET ops_assignment_escalation_notice_sent_at = now() WHERE id = $1::uuid AND ops_assignment_escalation_notice_sent_at IS NULL RETURNING id"
  }

  @release_columns %{
    "ops_new_booking_notice_sent_at" =>
      "UPDATE public.bookings SET ops_new_booking_notice_sent_at = NULL WHERE id = $1::uuid",
    "ops_confirmed_reminder_sent_at" =>
      "UPDATE public.bookings SET ops_confirmed_reminder_sent_at = NULL WHERE id = $1::uuid",
    "ops_assignment_escalation_notice_sent_at" =>
      "UPDATE public.bookings SET ops_assignment_escalation_notice_sent_at = NULL WHERE id = $1::uuid"
  }

  defp claim_notice(booking_id, column) do
    case Map.fetch(@notice_columns, column) do
      {:ok, sql} -> match?({:ok, %{num_rows: 1}}, Repo.query(sql, [booking_id]))
      :error -> false
    end
  end

  defp release_notice(booking_id, column) do
    case Map.fetch(@release_columns, column) do
      {:ok, sql} -> Repo.query(sql, [booking_id])
      :error -> {:error, :invalid_column}
    end
  end

  defp mark_unassigned_sent(booking_id) do
    Repo.query(
      "UPDATE public.bookings SET ops_unassigned_paid_notice_sent_at = now() WHERE id = $1::uuid",
      [booking_id]
    )
  end

  defp admin_bookings_url do
    Application.get_env(:mithril, :app_url, "https://tryinstaclean.com")
    |> to_string()
    |> String.trim_trailing("/")
    |> Kernel.<>("/admin/bookings")
  end
end
