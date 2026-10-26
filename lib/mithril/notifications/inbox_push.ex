defmodule Mithril.Notifications.InboxPush do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Notifications.ExpoPush
  alias Mithril.Repo

  @offer_types ~w(job_offer broadcast_assignment_offer direct_assignment_offer direct_assignment_reminder)

  @spec deliver(map(), keyword()) :: :ok | {:error, term()}
  def deliver(payload, opts \\ []) when is_map(payload) do
    case push_fields(payload) do
      {:ok, push} ->
        tokens = load_tokens(push.user_id, opts)
        sender = Keyword.get(opts, :push, &ExpoPush.send_tokens/2)

        results =
          tokens
          |> Enum.group_by(&channel(push.type, &1.channel_version))
          |> Enum.map(fn {channel_id, group} ->
            delivered = sender.(
              Enum.map(group, & &1.token),
              %{
                title: push.title,
                body: push.body,
                sound: sound(push.type),
                channel_id: channel_id,
                badge: push.badge,
                interruption_level: interruption_level(push.type),
                data: push.data
              }
            )

            delivered == length(group)
          end)

        if Enum.all?(results), do: :ok, else: {:error, :push_delivery_failed}

      :skip ->
        :ok
    end
  end

  @spec sound(String.t()) :: String.t()
  def sound(type) when type in @offer_types, do: "instaclean_job_offer.wav"
  def sound(_type), do: "default"

  @spec channel(String.t(), integer() | nil) :: String.t()
  def channel(type, version) when type in @offer_types do
    if is_integer(version) and version >= 3, do: "job_offers_v3", else: "job_offers_v2"
  end

  def channel("booking_cancelled", _version), do: "booking_cancellations"
  def channel("unassigned_booking_escalated", _version), do: "booking_cancellations"
  def channel("new_message", _version), do: "messages"
  def channel("cleaner_en_route", _version), do: "cleaner_milestones"
  def channel("cleaner_arrived", _version), do: "cleaner_milestones"
  def channel(_type, _version), do: "booking_updates"

  @spec interruption_level(String.t()) :: String.t() | nil
  def interruption_level(type)
      when type in ~w(cleaner_en_route cleaner_arrived booking_cancelled booking_rescheduled payment_required direct_assignment_offer direct_assignment_reminder),
      do: "time-sensitive"

  def interruption_level(_type), do: nil

  defp push_fields(payload) do
    user_id = text(payload, "user_id")
    title = text(payload, "title")
    body = text(payload, "body")
    type = text(payload, "type")
    data = payload |> field("data") |> data_map(type)

    if user_id && title && body && type do
      {:ok,
       %{
         user_id: user_id,
         title: title,
         body: body,
         type: type,
         data: data,
         badge: unread_badge(user_id)
       }}
    else
      :skip
    end
  end

  defp data_map(data, type) when is_map(data) do
    data =
      if Map.has_key?(data, "type") or Map.has_key?(data, :type) do
        data
      else
        Map.put(data, "type", type)
      end

    if type in @offer_types and
         not (Map.has_key?(data, "audience") or Map.has_key?(data, :audience)) do
      Map.put(data, "audience", "worker")
    else
      data
    end
  end

  defp data_map(_data, type) do
    data = %{"type" => type}

    if type in @offer_types do
      Map.put(data, "audience", "worker")
    else
      data
    end
  end

  defp unread_badge(user_id) do
    case Repo.query(
           """
           SELECT least(greatest(count(*)::integer, 1), 999)
           FROM public.notifications
           WHERE user_id = $1::uuid
             AND read = false
           """,
           [DbUuid.dump!(user_id)]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> count
      _ -> 1
    end
  end

  defp load_tokens(user_id, opts) do
    case Keyword.get(opts, :tokens) do
      tokens when is_list(tokens) ->
        Enum.map(tokens, fn
          %{token: token, channel_version: version} ->
            %{token: token, channel_version: version}

          token when is_binary(token) ->
            %{token: token, channel_version: nil}
        end)

      _ ->
        case Repo.query(
               """
               SELECT token, max(channel_version)::integer
               FROM (
                 SELECT dt.token, dt.android_notification_channel_version AS channel_version
                 FROM public.device_tokens dt
                 WHERE dt.user_id = $1::uuid
                 UNION ALL
                 SELECT cd.expo_push_token, NULL::integer
                 FROM public.cleaner_devices cd
                 WHERE cd.cleaner_id = $1::uuid
               ) devices
               WHERE token ~ '^(Expo(nent)?PushToken)\\[.+\\]$'
               GROUP BY token
               """,
               [DbUuid.dump!(user_id)]
             ) do
          {:ok, %{rows: rows}} ->
            Enum.map(rows, fn [token, version] ->
              %{token: token, channel_version: version}
            end)

          _ ->
            []
        end
    end
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp field(_, _), do: nil

  defp text(map, key) do
    case field(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end
end
