defmodule Mithril.MobileFunctions.SendAppNotification do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Notifications.SendNotification
  alias Mithril.Repo

  @expo_token_regex ~r/^(Expo(nent)?PushToken)\[.+\]$/
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @milestone_types ~w(cleaner_en_route cleaner_arrived)

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(cleaner_user_id, body) when is_binary(cleaner_user_id) and is_map(body) do
    type = body |> Map.get("type", "") |> to_string() |> String.trim()
    target_user_id = body |> Map.get("targetUserId", "") |> to_string() |> String.trim()

    payload =
      case Map.get(body, "payload") do
        value when is_map(value) -> value
        _ -> %{}
      end

    booking_id = booking_id_from_payload(payload)

    cond do
      type == "" or target_user_id == "" ->
        {:error, {:status, 400, %{success: false, error: "Missing type or targetUserId"}}}

      type not in @milestone_types ->
        {:error, {:status, 400, %{success: false, error: "Unsupported notification type"}}}

      booking_id == "" or not Regex.match?(@uuid_regex, booking_id) ->
        {:error, {:status, 400, %{success: false, error: "Missing bookingId in payload"}}}

      true ->
        deliver_milestone(cleaner_user_id, target_user_id, type, booking_id)
    end
  end

  defp deliver_milestone(cleaner_user_id, target_user_id, type, booking_id) do
    with {:ok, booking} <- load_booking(booking_id),
         :ok <- ensure_cleaner_assignment(booking, cleaner_user_id),
         :ok <- ensure_target_customer(booking, target_user_id),
         :ok <- ensure_booking_status(booking, type) do
      targets = load_push_targets(target_user_id)
      {:ok, cleaner_name} = load_cleaner_name(cleaner_user_id)
      sent = send_expo_push(targets, type, booking_id, cleaner_name, target_user_id)
      channel_results = notify_customer_channels(target_user_id, booking, cleaner_name, type)

      {:ok,
       %{
         success: true,
         sent: sent,
         reason: if(sent == 0, do: "no_tokens", else: nil),
         customerEmailSms: channel_results.customer_notified,
         supportEmail: channel_results.support_notified
       }}
    else
      {:error, {:status, status, body}} -> {:error, {:status, status, body}}
    end
  end

  defp booking_id_from_payload(payload) do
    cond do
      is_binary(Map.get(payload, "bookingId")) -> String.trim(payload["bookingId"])
      is_binary(Map.get(payload, "booking_id")) -> String.trim(payload["booking_id"])
      true -> ""
    end
  end

  defp load_booking(booking_id) do
    sql = """
    SELECT id, cleaner_id, customer_id, customer_contact_phone, status, address,
           scheduled_date, scheduled_time, title
    FROM public.bookings
    WHERE id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(booking_id)]) do
      {:ok, %{columns: columns, rows: [row]}} ->
        {:ok, Map.new(Enum.zip(columns, row))}

      {:ok, %{rows: []}} ->
        {:error, {:status, 404, %{success: false, error: "Booking not found"}}}

      {:error, _} ->
        {:error, {:status, 404, %{success: false, error: "Booking not found"}}}
    end
  end

  defp ensure_cleaner_assignment(booking, cleaner_user_id) do
    if DbUuid.equal?(Map.get(booking, "cleaner_id"), cleaner_user_id) do
      :ok
    else
      {:error, {:status, 403, %{success: false, error: "Not the assigned cleaner"}}}
    end
  end

  defp ensure_target_customer(booking, target_user_id) do
    if DbUuid.equal?(Map.get(booking, "customer_id"), target_user_id) do
      :ok
    else
      {:error, {:status, 400, %{success: false, error: "targetUserId mismatch"}}}
    end
  end

  defp ensure_booking_status(booking, type) do
    expected_status = if type == "cleaner_en_route", do: "en_route", else: "arrived"

    if Map.get(booking, "status") == expected_status do
      :ok
    else
      {:error, {:status, 409, %{success: false, error: "Booking status mismatch"}}}
    end
  end

  defp load_push_targets(user_id) do
    sql = """
    SELECT expo_push_token AS token
    FROM public.cleaner_devices
    WHERE cleaner_id = $1::uuid AND expo_push_token IS NOT NULL
    UNION
    SELECT token
    FROM public.device_tokens
    WHERE user_id = $1::uuid AND token IS NOT NULL
    """

    case Repo.query(sql, [DbUuid.dump!(user_id)]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [token] -> token end)
        |> Enum.filter(&expo_token?/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp expo_token?(token) when is_binary(token), do: Regex.match?(@expo_token_regex, token)
  defp expo_token?(_), do: false

  defp load_cleaner_name(cleaner_user_id) do
    sql = """
    SELECT fullname, firstname
    FROM public.profiles
    WHERE id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(cleaner_user_id)]) do
      {:ok, %{rows: [[fullname, firstname]]}} ->
        {:ok, fullname || firstname || "Your cleaner"}

      _ ->
        {:ok, "Your cleaner"}
    end
  end

  defp send_expo_push(targets, type, booking_id, cleaner_name, target_user_id)
       when is_list(targets) do
    if targets == [] do
      0
    else
      push_title =
        if type == "cleaner_en_route",
          do: "#{cleaner_name} is on the way",
          else: "#{cleaner_name} has arrived"

      push_body =
        if type == "cleaner_en_route",
          do: "Your cleaner is heading to your location.",
          else: "Your cleaner has arrived at your location."

      badge = compute_app_badge_total(target_user_id)

      messages =
        Enum.map(targets, fn token ->
          %{
            to: token,
            title: push_title,
            body: push_body,
            sound: "default",
            priority: "high",
            channelId: "cleaner_milestones",
            badge: badge,
            data: %{
              type: type,
              bookingId: booking_id,
              screen: "/booking-live-tracking"
            }
          }
        end)

      _ = Req.post("https://exp.host/--/api/v2/push/send", json: messages)
      length(targets)
    end
  end

  defp compute_app_badge_total(user_id) do
    notif_sql = """
    SELECT COUNT(*)::int
    FROM public.notifications
    WHERE user_id = $1::uuid AND read = false
    """

    conv_sql = """
    SELECT COALESCE(SUM(unread_count), 0)::int
    FROM public.conversation_list
    WHERE customer_id = $1::uuid OR cleaner_id = $1::uuid
    """

    notif_count =
      case Repo.query(notif_sql, [DbUuid.dump!(user_id)]) do
        {:ok, %{rows: [[count]]}} when is_integer(count) -> count
        _ -> 0
      end

    message_count =
      case Repo.query(conv_sql, [DbUuid.dump!(user_id)]) do
        {:ok, %{rows: [[count]]}} when is_integer(count) -> count
        _ -> 0
      end

    (notif_count + message_count)
    |> max(0)
    |> min(999)
  end

  defp notify_customer_channels(customer_id, booking, cleaner_name, type) do
    milestone = if type == "cleaner_en_route", do: "en_route", else: "arrived"
    template = if milestone == "en_route", do: "cleaner_en_route", else: "cleaner_arrived"

    {customer_email, customer_phone, customer_name} = load_customer_contact(customer_id)
    time_short = format_time_short(Map.get(booking, "scheduled_time"))
    scheduled_date = Map.get(booking, "scheduled_date")

    date_combined =
      if scheduled_date && time_short != "",
        do: "#{scheduled_date} #{time_short}",
        else: to_string(scheduled_date || "")

    variables = %{
      "name" => customer_name,
      "cleanerName" => cleaner_name,
      "bookingId" => to_string(Map.get(booking, "id")),
      "date" => date_combined,
      "address" => Map.get(booking, "address") || "",
      "scheduled_date" => to_string(scheduled_date || ""),
      "scheduled_time" => to_string(Map.get(booking, "scheduled_time") || ""),
      "milestone" => milestone
    }

    channel =
      cond do
        customer_email && customer_phone -> "both"
        customer_email -> "email"
        customer_phone -> "sms"
        true -> nil
      end

    customer_notified =
      if channel do
        body =
          %{
            "template" => template,
            "channel" => channel,
            "userId" => customer_id,
            "bookingId" => to_string(Map.get(booking, "id")),
            "messageType" => type,
            "smsFallbackToWhatsapp" => true,
            "variables" => variables
          }
          |> maybe_put("email", customer_email)
          |> maybe_put("phone", customer_phone)

        match?({:ok, _}, SendNotification.invoke_mobile(body))
      else
        false
      end

    support_email = Application.get_env(:mithril, :support_email, "support@tryinstaclean.com")

    support_notified =
      match?(
        {:ok, _},
        SendNotification.invoke_mobile(%{
          "template" => "cleaner_milestone_support",
          "channel" => "email",
          "email" => support_email,
          "variables" =>
            Map.merge(variables, %{
              "customerName" => customer_name,
              "customerEmail" => customer_email || "",
              "customerPhone" => customer_phone || "",
              "supportEmail" => support_email,
              "milestoneLabel" => if(milestone == "en_route", do: "On my way", else: "Arrived"),
              "notificationType" => type
            })
        })
      )

    %{customer_notified: customer_notified, support_notified: support_notified}
  end

  defp load_customer_contact(customer_id) do
    user_sql = "SELECT email, phone FROM public.users WHERE id = $1::uuid LIMIT 1"
    profile_sql = "SELECT fullname, firstname FROM public.profiles WHERE id = $1::uuid LIMIT 1"

    {email, phone} =
      case Repo.query(user_sql, [DbUuid.dump!(customer_id)]) do
        {:ok, %{rows: [[email, phone]]}} -> {present(email), present(phone)}
        _ -> {nil, nil}
      end

    name =
      case Repo.query(profile_sql, [DbUuid.dump!(customer_id)]) do
        {:ok, %{rows: [[fullname, firstname]]}} -> fullname || firstname || "there"
        _ -> "there"
      end

    {email, phone, name}
  end

  defp format_time_short(raw) do
    value = to_string(raw || "") |> String.trim()

    case Regex.run(~r/^(\d{1,2}:\d{2})/, value) do
      [_, time] -> time
      _ -> String.slice(value, 0, 5)
    end
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_), do: nil
end
