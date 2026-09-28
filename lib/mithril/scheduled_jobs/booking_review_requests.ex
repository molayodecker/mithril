defmodule Mithril.ScheduledJobs.BookingReviewRequests do
  @moduledoc false

  alias Mithril.BookingReviewRequest
  alias Mithril.Notifications.{ExpoPush, SendNotification}
  alias Mithril.Repo

  @batch_limit 50

  @booking_select ~w(id customer_id cleaner_id customer_contact_phone title scheduled_date scheduled_time address status payment_status completed_at review_request_token)

  @spec run() :: :ok | {:error, term()}
  def run do
    now_ms = System.system_time(:millisecond)

    delay_hours =
      BookingReviewRequest.parse_delay_hours(System.get_env("BOOKING_REVIEW_REQUEST_DELAY_HOURS"))

    with {:ok, candidates} <- load_candidates() do
      due_rows =
        candidates
        |> Enum.filter(fn row ->
          completed_at = parse_completed_at(row["completed_at"])
          BookingReviewRequest.due?(completed_at, now_ms, delay_hours)
        end)

      with {:ok, reviews} <- load_reviews(due_rows) do
        reviewed_ids = BookingReviewRequest.reviewed_booking_ids(due_rows, reviews)

        due_rows
        |> BookingReviewRequest.filter_pending(reviewed_ids)
        |> Enum.take(@batch_limit)
        |> Enum.each(&deliver_review_request/1)

        :ok
      end
    end
  end

  defp load_candidates do
    case Repo.query(
           """
           SELECT #{Enum.join(@booking_select, ", ")}
           FROM public.bookings
           WHERE payment_status = 'paid'
             AND status = 'completed'
             AND cleaner_id IS NOT NULL
             AND review_request_sent_at IS NULL
             AND completed_at IS NOT NULL
           ORDER BY completed_at ASC
           LIMIT $1
           """,
           [@batch_limit * 3]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_map/1)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_reviews(bookings) do
    booking_ids = Enum.map(bookings, & &1["id"])

    if booking_ids == [] do
      {:ok, []}
    else
      case Repo.query(
             "SELECT booking_id, reviewer_id FROM public.reviews WHERE booking_id = ANY($1::uuid[])",
             [booking_ids]
           ) do
        {:ok, %{rows: rows}} ->
          {:ok,
           Enum.map(rows, fn [booking_id, reviewer_id] ->
             %{"booking_id" => booking_id, "reviewer_id" => reviewer_id}
           end)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp deliver_review_request(row) do
    booking_id = row["id"]

    case claim_review_request(booking_id) do
      :claimed ->
        if notify_customer(row) do
          stamp_sent(booking_id)
        else
          release_claim(booking_id)
        end

      _ ->
        :ok
    end
  end

  defp claim_review_request(booking_id) do
    case Repo.query("SELECT public.claim_booking_review_request($1::uuid)", [booking_id]) do
      {:ok, %{rows: [[claimed_at]]}} when not is_nil(claimed_at) -> :claimed
      _ -> :not_claimed
    end
  end

  defp release_claim(booking_id) do
    Repo.query(
      "UPDATE public.bookings SET review_request_claimed_at = NULL WHERE id = $1::uuid",
      [booking_id]
    )
  end

  defp stamp_sent(booking_id) do
    Repo.query(
      """
      UPDATE public.bookings
      SET review_request_sent_at = now(), review_request_claimed_at = NULL
      WHERE id = $1::uuid AND review_request_sent_at IS NULL
      """,
      [booking_id]
    )
  end

  defp notify_customer(row) do
    token = row["review_request_token"] || row["id"]
    app_url = Application.get_env(:mithril, :app_url, "https://tryinstaclean.com")
    review_url = BookingReviewRequest.build_url(app_url, to_string(token))
    customer = load_customer(row["customer_id"])
    cleaner_name = load_cleaner_name(row["cleaner_id"])
    booking_id = to_string(row["id"])

    push_title = "How was your clean?"
    push_body = "Rate #{cleaner_name} for your #{service_title(row)}."

    inbox = insert_inbox(row["customer_id"], push_title, push_body, booking_id, token)
    push_sent = send_push(row["customer_id"], push_title, push_body, booking_id, token)
    channels = send_channels(row, customer, cleaner_name, review_url, booking_id)

    BookingReviewRequest.active_delivered?(
      Map.merge(channels, %{push_sent: push_sent, inbox_inserted: inbox})
    )
  end

  defp insert_inbox(customer_id, title, message, booking_id, token) do
    dedupe = "review_request:#{booking_id}"
    screen = "/review/#{token}"

    case Repo.query(
           """
           INSERT INTO public.notifications (user_id, type, title, message, read, dedupe_key, data)
           VALUES ($1::uuid, 'review_request', $2, $3, false, $4, $5::jsonb)
           RETURNING id
           """,
           [
             customer_id,
             title,
             message,
             dedupe,
             Jason.encode!(%{
               "booking_id" => booking_id,
               "type" => "review_request",
               "review_token" => token,
               "screen" => screen
             })
           ]
         ) do
      {:ok, %{num_rows: 1}} -> true
      {:error, %{postgres: %{code: "23505"}}} -> true
      _ -> false
    end
  end

  defp send_push(customer_id, title, body, booking_id, token) do
    tokens =
      case Repo.query("SELECT token FROM public.device_tokens WHERE user_id = $1::uuid", [
             customer_id
           ]) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [token] -> token end)
        _ -> []
      end

    ExpoPush.send_tokens(tokens, %{
      title: title,
      body: body,
      data: %{
        "type" => "review_request",
        "bookingId" => booking_id,
        "review_token" => token,
        "screen" => "/review/#{token}"
      }
    })
  end

  defp send_channels(row, customer, cleaner_name, review_url, booking_id) do
    email = trim(customer[:email])
    phone = trim(row["customer_contact_phone"]) || trim(customer[:phone])

    channel =
      cond do
        is_nil(email) and is_nil(phone) -> nil
        email && phone -> "both"
        email -> "email"
        true -> "sms"
      end

    if channel == nil or not SendNotification.configured?() do
      %{email_sent: false, sms_sent: false, whatsapp_sent: false}
    else
      date =
        "#{row["scheduled_date"]} #{row["scheduled_time"]}"
        |> String.trim()

      body = %{
        "template" => "review_request",
        "channel" => channel,
        "userId" => row["customer_id"],
        "bookingId" => booking_id,
        "messageType" => "review_request",
        "smsFallbackToWhatsapp" => true,
        "email" => email,
        "phone" => phone,
        "variables" => %{
          "name" => customer[:name] || "there",
          "bookingId" => booking_id,
          "cleanerName" => cleaner_name,
          "date" => date,
          "reviewUrl" => review_url,
          "title" => service_title(row)
        }
      }

      case SendNotification.invoke_mobile(body) do
        {:ok, response} ->
          %{
            email_sent: truthy?(response["emailSent"]),
            sms_sent: truthy?(response["smsSent"]),
            whatsapp_sent: truthy?(response["whatsappSent"])
          }

        _ ->
          %{email_sent: false, sms_sent: false, whatsapp_sent: false}
      end
    end
  end

  defp load_customer(customer_id) do
    case Repo.query(
           """
           SELECT u.email, u.phone,
                  COALESCE(NULLIF(btrim(p.fullname), ''), NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''), 'Customer')
           FROM public.users u
           LEFT JOIN public.profiles p ON p.id = u.id
           WHERE u.id = $1::uuid
           """,
           [customer_id]
         ) do
      {:ok, %{rows: [[email, phone, name]]}} -> %{email: email, phone: phone, name: name}
      _ -> %{email: nil, phone: nil, name: "Customer"}
    end
  end

  defp load_cleaner_name(cleaner_id) do
    case Repo.query(
           """
           SELECT COALESCE(NULLIF(btrim(p.fullname), ''), NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''), 'your cleaner')
           FROM public.profiles p WHERE p.id = $1::uuid
           """,
           [cleaner_id]
         ) do
      {:ok, %{rows: [[name]]}} -> name
      _ -> "your cleaner"
    end
  end

  defp parse_completed_at(%DateTime{} = dt), do: dt

  defp parse_completed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_completed_at(_), do: nil

  defp service_title(row) do
    case row["title"] |> to_string() |> String.trim() do
      "" -> "cleaning"
      title -> title
    end
  end

  defp row_to_map(row), do: Map.new(Enum.zip(@booking_select, row))

  defp trim(nil), do: nil

  defp trim(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp trim(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
