defmodule Mithril.PropertyCalendarSync do
  @moduledoc false

  require Logger

  alias Mithril.CalendarFeedSecurity
  alias Mithril.PropertyCalendar.IcalSync
  alias Mithril.Repo
  alias Mithril.SecretCrypto

  @batch_limit 20

  @doc false
  @spec batch_limit() :: pos_integer()
  def batch_limit, do: @batch_limit

  @spec sync_batch() :: :ok | {:error, term()}
  def sync_batch do
    stale_before =
      DateTime.utc_now()
      |> DateTime.add(-30, :minute)
      |> DateTime.to_iso8601()

    case Repo.query(
           """
           SELECT id, property_id, feed_url_encrypted, timezone, minimum_turnover_minutes,
                  default_checkout_time, default_checkin_time, provider
           FROM public.property_calendar_feeds
           WHERE sync_enabled = true
             AND (last_synced_at IS NULL OR last_synced_at <= $1::timestamptz)
           ORDER BY last_synced_at ASC NULLS FIRST
           LIMIT $2
           """,
           [stale_before, @batch_limit]
         ) do
      {:ok, %{columns: columns, rows: rows}} ->
        Enum.each(rows, fn row ->
          feed = Map.new(Enum.zip(columns, row))
          sync_feed(feed)
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp sync_feed(feed) do
    feed_id = feed["id"]
    started = DateTime.utc_now() |> DateTime.to_iso8601()
    mark_sync_started(feed_id, started)

    with {:ok, feed_url} <- decrypt_feed(feed["feed_url_encrypted"]),
         {:ok, ics_text} <-
           CalendarFeedSecurity.fetch_feed_text(feed_url, feed["provider"] || "airbnb"),
         :ok <- IcalSync.import_feed(feed, ics_text) do
      success_at = DateTime.utc_now() |> DateTime.to_iso8601()

      Repo.query(
        """
        UPDATE public.property_calendar_feeds
        SET last_successful_sync_at = $2::timestamptz, last_sync_error = NULL, updated_at = $2::timestamptz
        WHERE id = $1::uuid
        """,
        [feed_id, success_at]
      )
    else
      {:error, message} ->
        failed_at = DateTime.utc_now() |> DateTime.to_iso8601()
        trimmed = message |> to_string() |> String.slice(0, 500)

        Repo.query(
          """
          UPDATE public.property_calendar_feeds
          SET last_sync_error = $2, updated_at = $3::timestamptz
          WHERE id = $1::uuid
          """,
          [feed_id, trimmed, failed_at]
        )

        Logger.warning("property_calendar_sync feed_id=#{feed_id} error=#{trimmed}")
    end
  end

  defp mark_sync_started(feed_id, started) do
    Repo.query(
      """
      UPDATE public.property_calendar_feeds
      SET last_synced_at = $2::timestamptz, updated_at = $2::timestamptz
      WHERE id = $1::uuid
      """,
      [feed_id, started]
    )
  end

  defp decrypt_feed(ciphertext) when is_binary(ciphertext) do
    case SecretCrypto.decrypt(ciphertext) do
      {:ok, url} -> {:ok, String.trim(url)}
      {:error, _} -> {:error, "Failed to decrypt feed URL"}
    end
  end

  defp decrypt_feed(_), do: {:error, "Failed to decrypt feed URL"}
end
