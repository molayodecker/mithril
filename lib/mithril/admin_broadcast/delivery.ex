defmodule Mithril.AdminBroadcast.Delivery do
  @moduledoc false

  alias Mithril.Auth.SMS
  alias Mithril.Notifications.ExpoPush
  alias Mithril.Repo

  @batch_size 50

  def batch_size, do: @batch_size

  @spec parse_recipient_ids(term()) :: [String.t()]
  def parse_recipient_ids(raw) when is_list(raw) do
    raw
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_recipient_ids(_), do: []

  @spec parse_stats(term()) :: map()
  def parse_stats(raw) when is_map(raw), do: normalize_stats(raw)
  def parse_stats(raw) when is_binary(raw), do: raw |> Jason.decode!() |> normalize_stats()
  def parse_stats(_), do: empty_stats()

  @spec merge_stats(term(), map()) :: map()
  def merge_stats(base_raw, delta) do
    base = parse_stats(base_raw)

    Map.merge(base, %{
      "fetched" => base["fetched"] + delta["fetched"],
      "skippedPrefs" => base["skippedPrefs"] + delta["skippedPrefs"],
      "attempted" => base["attempted"] + delta["attempted"],
      "inAppCreated" => base["inAppCreated"] + delta["inAppCreated"],
      "pushDevicesSent" => base["pushDevicesSent"] + delta["pushDevicesSent"],
      "smsSent" => base["smsSent"] + delta["smsSent"],
      "whatsappSent" => base["whatsappSent"] + delta["whatsappSent"],
      "failed" => base["failed"] + delta["failed"]
    })
  end

  @spec delivered_any?(map()) :: boolean()
  def delivered_any?(stats) do
    stats["inAppCreated"] > 0 or stats["pushDevicesSent"] > 0 or stats["smsSent"] > 0 or
      stats["whatsappSent"] > 0
  end

  @spec deliver_batch(map(), [String.t()]) :: map()
  def deliver_batch(broadcast, user_ids) do
    channels = parse_channels(broadcast["channels"])
    recipients = hydrate_recipients(user_ids)
    stats = empty_stats()
    stats = %{stats | "fetched" => length(recipients)}

    Enum.reduce(recipients, stats, fn recipient, acc ->
      if skip_recipient?(recipient, channels, broadcast["requires_marketing_consent"]) do
        %{acc | "skippedPrefs" => acc["skippedPrefs"] + 1}
      else
        deliver_to_recipient(broadcast, recipient, channels, %{
          acc
          | "attempted" => acc["attempted"] + 1
        })
      end
    end)
  end

  defp deliver_to_recipient(broadcast, recipient, channels, stats) do
    failed = false

    {stats, failed} =
      if channels.in_app_push do
        case insert_notification(recipient.user_id, broadcast) do
          :ok -> {%{stats | "inAppCreated" => stats["inAppCreated"] + 1}, failed}
          :error -> {stats, true}
        end
      else
        {stats, failed}
      end

    stats =
      if channels.in_app_push and recipient.push_enabled do
        sent =
          ExpoPush.send_tokens(recipient.push_tokens, %{
            title: broadcast["title"],
            body: broadcast["message"],
            data: %{
              "type" => broadcast["notification_type"],
              "screen" => broadcast["screen"] || ""
            }
          })

        %{stats | "pushDevicesSent" => stats["pushDevicesSent"] + sent}
      else
        stats
      end

    stats =
      if channels.sms and recipient.messaging_enabled and recipient.phone_e164 do
        if SMS.send_message(recipient.phone_e164, broadcast["message"]) == :ok do
          %{stats | "smsSent" => stats["smsSent"] + 1}
        else
          %{stats | "failed" => stats["failed"] + 1}
        end
      else
        stats
      end

    if failed, do: %{stats | "failed" => stats["failed"] + 1}, else: stats
  end

  defp insert_notification(user_id, broadcast) do
    data =
      if is_binary(broadcast["screen"]) and broadcast["screen"] != "" do
        Jason.encode!(%{"screen" => broadcast["screen"]})
      else
        "{}"
      end

    case Repo.query(
           """
           INSERT INTO public.notifications (user_id, type, title, message, read, data)
           VALUES ($1::uuid, $2, $3, $4, false, $5::jsonb)
           """,
           [
             user_id,
             broadcast["notification_type"],
             broadcast["title"],
             broadcast["message"],
             data
           ]
         ) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp hydrate_recipients(user_ids) do
    case Repo.query(
           """
           SELECT u.id, u.phone, p.notification_settings,
                  array_remove(array_agg(DISTINCT dt.token), NULL) AS push_tokens
           FROM public.users u
           LEFT JOIN public.profiles p ON p.id = u.id
           LEFT JOIN public.device_tokens dt ON dt.user_id = u.id
           WHERE u.id = ANY($1::uuid[])
           GROUP BY u.id, u.phone, p.notification_settings
           """,
           [user_ids]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [user_id, phone, settings, tokens] ->
          prefs = parse_settings(settings)

          %{
            user_id: user_id,
            phone_e164: normalize_phone(phone),
            push_enabled: prefs.push,
            messaging_enabled: prefs.sms,
            marketing_enabled: prefs.marketing,
            push_tokens: tokens || []
          }
        end)

      _ ->
        []
    end
  end

  defp parse_settings(nil), do: %{push: true, sms: true, marketing: false}

  defp parse_settings(settings) when is_map(settings) do
    %{
      push: Map.get(settings, "push", true) != false,
      sms: Map.get(settings, "sms", true) != false,
      marketing: Map.get(settings, "marketing", false) == true
    }
  end

  defp parse_settings(_), do: %{push: true, sms: true, marketing: false}

  defp parse_channels(nil), do: %{in_app_push: false, sms: false, whatsapp: false}

  defp parse_channels(raw) when is_map(raw) do
    %{
      in_app_push: Map.get(raw, "inAppPush") == true,
      sms: Map.get(raw, "sms") == true,
      whatsapp: Map.get(raw, "whatsapp") == true
    }
  end

  defp parse_channels(_), do: %{in_app_push: false, sms: false, whatsapp: false}

  defp skip_recipient?(recipient, channels, requires_marketing?) do
    requires_marketing? and not recipient.marketing_enabled and
      (channels.sms or channels.whatsapp)
  end

  defp normalize_phone(nil), do: nil

  defp normalize_phone(phone) when is_binary(phone) do
    trimmed = String.trim(phone)
    if trimmed == "", do: nil, else: trimmed
  end

  defp empty_stats do
    %{
      "fetched" => 0,
      "skippedPrefs" => 0,
      "attempted" => 0,
      "inAppCreated" => 0,
      "pushDevicesSent" => 0,
      "smsSent" => 0,
      "whatsappSent" => 0,
      "failed" => 0
    }
  end

  defp normalize_stats(map) do
    %{
      "fetched" => int(map, "fetched"),
      "skippedPrefs" => int(map, "skippedPrefs"),
      "attempted" => int(map, "attempted"),
      "inAppCreated" => int(map, "inAppCreated"),
      "pushDevicesSent" => int(map, "pushDevicesSent"),
      "smsSent" => int(map, "smsSent"),
      "whatsappSent" => int(map, "whatsappSent"),
      "failed" => int(map, "failed")
    }
  end

  defp int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end
end
