defmodule Mithril.MobileFunctions.NotifyBookingRescheduled do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Notifications.SendNotification
  alias Mithril.Repo

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  def call(user_id, body) when is_map(body) do
    booking_id = body |> Map.get("bookingId", "") |> to_string() |> String.trim()
    old_date = body |> Map.get("oldScheduledDate", "") |> to_string() |> String.trim()
    old_time = normalize_time(Map.get(body, "oldScheduledTime"))
    new_date = body |> Map.get("newScheduledDate", "") |> to_string() |> String.trim()
    new_time = normalize_time(Map.get(body, "newScheduledTime"))
    location_changed = Map.get(body, "locationChanged") == true

    cond do
      booking_id == "" or old_date == "" or new_date == "" or old_time == "" or new_time == "" ->
        {:error, {:status, 400, %{success: false, error: "Missing required schedule fields"}}}

      not Regex.match?(@uuid_regex, booking_id) ->
        {:error, {:status, 400, %{success: false, error: "Invalid bookingId"}}}

      true ->
        with {:ok, booking} <- load_booking(booking_id),
             :ok <- ensure_customer(booking, user_id),
             {:ok, skipped} <- skip_reason(booking),
             :ok <- ensure_schedule_match(booking, new_date, new_time) do
          if skipped do
            {:ok, Map.put(skipped, :success, true)}
          else
            notify_parties(
              booking,
              old_date,
              old_time,
              new_date,
              new_time,
              location_changed,
              booking_id
            )
          end
        end
    end
  end

  defp load_booking(booking_id) do
    sql = """
    SELECT id, customer_id, cleaner_id, scheduled_date, scheduled_time, payment_status, status, subscription_id
    FROM public.bookings WHERE id = $1::uuid LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(booking_id)]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, map_row(columns, row)}
      _ -> {:error, {:status, 404, %{success: false, error: "Booking not found"}}}
    end
  end

  defp ensure_customer(booking, user_id) do
    if DbUuid.equal?(Map.get(booking, "customer_id"), user_id) do
      :ok
    else
      {:error, {:status, 403, %{success: false, error: "Forbidden"}}}
    end
  end

  defp skip_reason(booking) do
    cond do
      is_nil(Map.get(booking, "cleaner_id")) ->
        {:ok, %{skipped: true, reason: "no_assigned_cleaner"}}

      Map.get(booking, "subscription_id") not in [nil, ""] ->
        {:ok, %{skipped: true, reason: "subscription_booking"}}

      String.downcase(Map.get(booking, "payment_status", "")) not in ["paid", "success"] ->
        {:ok, %{skipped: true, reason: "not_paid"}}

      true ->
        {:ok, nil}
    end
  end

  defp ensure_schedule_match(booking, new_date, new_time) do
    db_date = Map.get(booking, "scheduled_date") |> to_string() |> String.trim()
    db_time = normalize_time(Map.get(booking, "scheduled_time"))

    if db_date == new_date and db_time == new_time do
      :ok
    else
      {:error, {:status, 409, %{success: false, error: "Booking schedule mismatch"}}}
    end
  end

  defp notify_parties(
         booking,
         old_date,
         old_time,
         new_date,
         new_time,
         location_changed,
         booking_id
       ) do
    customer_id = DbUuid.encode(Map.get(booking, "customer_id"))
    cleaner_id = DbUuid.encode(Map.get(booking, "cleaner_id"))
    old_label = "#{old_date} #{String.slice(old_time, 0, 5)}"
    new_label = "#{new_date} #{String.slice(new_time, 0, 5)}"
    title = "Booking rescheduled"

    customer_body =
      if location_changed,
        do:
          "Your booking has been updated to #{new_label}. The time and location were updated — open the booking for the latest details.",
        else: "Your booking has been updated to #{new_label}."

    cleaner_body = "Your booking has moved from #{old_label} to #{new_label}."

    customer_notified =
      insert_notification(
        customer_id,
        title,
        customer_body,
        booking_id,
        new_date,
        new_time,
        "customer"
      )

    cleaner_notified =
      insert_notification(
        cleaner_id,
        title,
        cleaner_body,
        booking_id,
        new_date,
        new_time,
        "cleaner"
      )

    _ = maybe_send_external(customer_id, booking_id, customer_body, new_label, old_label)
    _ = maybe_send_external(cleaner_id, booking_id, cleaner_body, new_label, old_label)

    {:ok,
     %{success: true, customerNotified: customer_notified, cleanerNotified: cleaner_notified}}
  end

  defp insert_notification(user_id, title, message, booking_id, new_date, new_time, audience) do
    dedupe = "booking_rescheduled:#{booking_id}:#{new_date}:#{new_time}:#{audience}"
    screen = if audience == "customer", do: "/booking-status", else: "/(tabs)/cleaner-dashboard"

    case Repo.query(
           """
           INSERT INTO public.notifications (user_id, type, title, message, read, dedupe_key, data)
           VALUES ($1::uuid, 'booking_rescheduled', $2, $3, false, $4, $5::jsonb)
           ON CONFLICT (dedupe_key) DO NOTHING
           """,
           [
             DbUuid.dump!(user_id),
             title,
             message,
             dedupe,
             Jason.encode!(%{
               booking_id: booking_id,
               bookingId: booking_id,
               type: "booking_rescheduled",
               audience: audience,
               new_scheduled_date: new_date,
               new_scheduled_time: new_time,
               screen: screen
             })
           ]
         ) do
      {:ok, %{num_rows: 1}} -> true
      {:ok, %{num_rows: 0}} -> true
      {:error, _} -> false
    end
  end

  defp maybe_send_external(user_id, booking_id, message, new_label, old_label) do
    if SendNotification.configured?() do
      SendNotification.invoke_mobile(%{
        "template" => "booking_rescheduled",
        "userId" => user_id,
        "bookingId" => booking_id,
        "variables" => %{
          "message" => message,
          "newDate" => new_label,
          "oldDate" => old_label,
          "bookingId" => booking_id
        }
      })
    end

    :ok
  end

  defp normalize_time(raw) do
    value = raw |> to_string() |> String.trim()

    cond do
      Regex.match?(~r/^\d{2}:\d{2}:\d{2}$/, value) ->
        value

      Regex.match?(~r/^\d{2}:\d{2}$/, value) ->
        "#{value}:00"

      true ->
        case Regex.run(~r/^(\d{1,2}:\d{2})/, value) do
          [_, hour_minute] -> "#{hour_minute}:00"
          _ -> value
        end
    end
  end

  defp map_row(columns, row), do: Map.new(Enum.zip(columns, row))
end
