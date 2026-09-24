defmodule Mithril.MobileFunctions.ConnectPropertyCalendar do
  @moduledoc false

  alias Mithril.CalendarFeedSecurity
  alias Mithril.MobileGateway
  alias Mithril.Repo
  alias Mithril.SecretCrypto

  @feed_columns ~w(
    id property_id provider timezone sync_enabled auto_create_turnovers
    minimum_turnover_minutes last_synced_at last_successful_sync_at last_sync_error
  )

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    with {:ok, fields} <- parse_body(body),
         {:ok, property} <- load_property(user_id, fields.property_id),
         timezone = effective_timezone(fields, property),
         :ok <-
           CalendarFeedSecurity.validate_feed_timing(%{
             timezone: timezone,
             default_checkin_time: fields.default_checkin_time,
             default_checkout_time: fields.default_checkout_time
           }),
         {:ok, encrypted} <- encrypt_feed(fields.feed_url),
         feed_hash = SecretCrypto.hash_token(fields.feed_url),
         {:ok, feed} <-
           replace_active_feed(user_id, fields, encrypted, feed_hash, timezone) do
      {:ok, %{feed: feed}}
    else
      {:error, {:status, status, body}} -> {:error, {:status, status, body}}
      {:error, message} when is_binary(message) -> {:error, {:status, 400, %{error: message}}}
    end
  end

  defp parse_body(body) do
    with {:ok, property_id} <-
           CalendarFeedSecurity.parse_property_id(Map.get(body, "property_id")),
         {:ok, provider} <- CalendarFeedSecurity.parse_provider(Map.get(body, "provider")),
         {:ok, feed_url} <- parse_feed_url(body, provider),
         {:ok, default_checkout_time} <-
           CalendarFeedSecurity.parse_feed_time(
             Map.get(body, "default_checkout_time"),
             "11:00:00"
           ),
         {:ok, default_checkin_time} <-
           CalendarFeedSecurity.parse_feed_time(Map.get(body, "default_checkin_time"), "15:00:00"),
         {:ok, minimum_turnover_minutes} <-
           CalendarFeedSecurity.parse_minimum_turnover_minutes(
             Map.get(body, "minimum_turnover_minutes")
           ) do
      timezone =
        case Map.get(body, "timezone") do
          value when is_binary(value) ->
            trimmed = String.trim(value)
            if trimmed == "", do: nil, else: trimmed

          _ ->
            nil
        end

      {:ok,
       %{
         property_id: property_id,
         provider: provider,
         feed_url: feed_url,
         requested_timezone: timezone,
         default_timezone: timezone || "Africa/Accra",
         default_checkout_time: default_checkout_time,
         default_checkin_time: default_checkin_time,
         minimum_turnover_minutes: minimum_turnover_minutes
       }}
    end
  end

  defp effective_timezone(fields, property) do
    property_timezone =
      case property do
        %{timezone: property_timezone}
        when is_binary(property_timezone) and property_timezone != "" ->
          property_timezone

        _ ->
          nil
      end

    if is_nil(fields.requested_timezone) and property_timezone do
      property_timezone
    else
      fields.default_timezone
    end
  end

  defp parse_feed_url(body, provider) do
    raw = Map.get(body, "feed_url", "") |> to_string()

    case CalendarFeedSecurity.assert_safe_feed_url(raw, provider) do
      :ok -> {:ok, String.trim(raw)}
      {:error, message} -> {:error, message}
    end
  end

  defp load_property(user_id, property_id) do
    case MobileGateway.with_user_transaction(user_id, fn ->
           case Repo.query(
                  """
                  SELECT timezone
                  FROM public.properties
                  WHERE id = $1::uuid AND customer_id = $2::uuid
                  LIMIT 1
                  """,
                  [property_id, user_id]
                ) do
             {:ok, %{rows: [[property_timezone]]}} ->
               {:ok, %{timezone: property_timezone}}

             {:ok, %{rows: []}} ->
               {:error, {:status, 404, %{error: "Property not found"}}}

             {:error, error} ->
               {:error, error}
           end
         end) do
      {:ok, property} ->
        {:ok, property}

      {:error, {:status, _, _} = error} ->
        {:error, error}

      {:error, _} ->
        {:error, {:status, 502, %{error: "Failed to verify property"}}}
    end
  end

  defp encrypt_feed(feed_url) do
    case SecretCrypto.encrypt(feed_url) do
      {:ok, encrypted} ->
        {:ok, encrypted}

      {:error, :not_configured} ->
        {:error, {:status, 500, %{error: "Calendar encryption is not configured"}}}
    end
  end

  defp replace_active_feed(user_id, fields, encrypted, feed_hash, timezone) do
    case Repo.transaction(fn ->
           with :ok <- disable_other_active_feeds(fields.property_id, feed_hash),
                {:ok, feed} <- upsert_feed(user_id, fields, encrypted, feed_hash, timezone) do
             feed
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, feed} ->
        {:ok, feed}

      {:error, {:status, _, _} = error} ->
        {:error, error}

      {:error, _} ->
        {:error, {:status, 502, %{error: "Failed to save calendar feed"}}}
    end
  end

  defp disable_other_active_feeds(property_id, feed_hash) do
    case Repo.query(
           """
           UPDATE public.property_calendar_feeds
           SET sync_enabled = false, updated_at = NOW()
           WHERE property_id = $1::uuid
             AND sync_enabled = true
             AND feed_url_hash <> $2::text
           """,
           [property_id, feed_hash]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp upsert_feed(user_id, fields, encrypted, feed_hash, timezone) do
    sql = """
    INSERT INTO public.property_calendar_feeds (
      property_id, owner_id, provider, feed_url_encrypted, feed_url_hash, timezone,
      sync_enabled, auto_create_turnovers, default_checkout_time, default_checkin_time,
      minimum_turnover_minutes, updated_at
    ) VALUES (
      $1::uuid, $2::uuid, $3::text, $4::text, $5::text, $6::text,
      true, false, $7::time, $8::time, $9::int, NOW()
    )
    ON CONFLICT (owner_id, feed_url_hash) DO UPDATE SET
      property_id = EXCLUDED.property_id,
      provider = EXCLUDED.provider,
      feed_url_encrypted = EXCLUDED.feed_url_encrypted,
      timezone = EXCLUDED.timezone,
      sync_enabled = EXCLUDED.sync_enabled,
      auto_create_turnovers = EXCLUDED.auto_create_turnovers,
      default_checkout_time = EXCLUDED.default_checkout_time,
      default_checkin_time = EXCLUDED.default_checkin_time,
      minimum_turnover_minutes = EXCLUDED.minimum_turnover_minutes,
      updated_at = NOW()
    RETURNING #{Enum.join(@feed_columns, ", ")}
    """

    case Repo.query(sql, [
           fields.property_id,
           user_id,
           fields.provider,
           encrypted,
           feed_hash,
           timezone,
           fields.default_checkout_time,
           fields.default_checkin_time,
           fields.minimum_turnover_minutes
         ]) do
      {:ok, %{columns: columns, rows: [row]}} ->
        {:ok, Map.new(Enum.zip(columns, row))}

      {:error, error} ->
        {:error,
         {:status, 502, %{error: db_error_message(error, "Failed to save calendar feed")}}}
    end
  end

  defp db_error_message(%Postgrex.Error{message: message}, fallback) when is_binary(message),
    do: fallback

  defp db_error_message(_, fallback), do: fallback
end
