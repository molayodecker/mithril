defmodule Mithril.Outbox do
  @moduledoc false

  require Logger

  alias Mithril.DbUuid
  alias Mithril.Notifications.{InboxPush, MessagePush}
  alias Mithril.PaystackCustomers
  alias Mithril.Repo

  @batch 25
  @max_attempts 8

  @spec drain(keyword()) :: :ok
  def drain(opts \\ []) do
    reclaim_stuck()

    case claim() do
      {:ok, rows} ->
        Enum.each(rows, &deliver(&1, opts))
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, reason} ->
        Logger.warning("outbox claim failed: #{inspect(reason)}")
        :ok
    end
  end

  defp deliver(%{id: id, kind: kind, payload: payload, attempts: attempts}, opts) do
    result =
      try do
        case kind do
          "inbox_push" -> InboxPush.deliver(payload, opts)
          "new_message" -> MessagePush.deliver(payload, opts)
          "paystack_customer" -> PaystackCustomers.ensure(payload)
          _ -> :ok
        end
      rescue
        error -> {:error, Exception.message(error)}
      end

    case result do
      :ok -> mark_sent(id)
      {:error, reason} -> mark_retry(id, attempts, reason)
    end
  end

  defp reclaim_stuck do
    Repo.query("""
    UPDATE public.mithril_outbox
    SET status = 'pending', claimed_at = NULL
    WHERE status = 'sending'
      AND claimed_at < now() - interval '5 minutes'
    """)
  end

  defp claim do
    Repo.query(
      """
      UPDATE public.mithril_outbox
      SET status = 'sending',
          attempts = attempts + 1,
          claimed_at = now()
      WHERE id IN (
        SELECT id
        FROM public.mithril_outbox
        WHERE status = 'pending'
          AND available_at <= now()
        ORDER BY inserted_at
        LIMIT $1
        FOR UPDATE SKIP LOCKED
      )
      RETURNING id, kind, payload, attempts
      """,
      [@batch]
    )
    |> case do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [id, kind, payload, attempts] ->
           %{id: id, kind: kind, payload: payload || %{}, attempts: attempts}
         end)}

      other ->
        other
    end
  end

  defp mark_sent(id) do
    Repo.query(
      """
      UPDATE public.mithril_outbox
      SET status = 'sent', sent_at = now(), last_error = NULL
      WHERE id = $1::uuid
      """,
      [DbUuid.dump!(id)]
    )
  end

  defp mark_retry(id, attempts, reason) do
    error = reason |> inspect() |> String.slice(0, 200)

    if attempts >= @max_attempts or reason in [:missing_email, :payment_not_configured] do
      Repo.query(
        """
        UPDATE public.mithril_outbox
        SET status = 'failed', last_error = $2
        WHERE id = $1::uuid
        """,
        [DbUuid.dump!(id), error]
      )
    else
      Repo.query(
        """
        UPDATE public.mithril_outbox
        SET status = 'pending',
            available_at = now() + make_interval(mins => $2),
            last_error = $3
        WHERE id = $1::uuid
        """,
        [DbUuid.dump!(id), attempts, error]
      )
    end
  end
end
