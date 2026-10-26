defmodule Mithril.Outbox do
  @moduledoc false

  require Logger

  alias Mithril.DbUuid
  alias Mithril.Notifications.{InboxPush, MessagePush}
  alias Mithril.PaystackCustomers
  alias Mithril.Repo

  @max_attempts 8

  @spec drain(keyword()) :: :ok
  def drain(opts \\ []) do
    reclaim_stuck()

    case claim() do
      {:ok, nil} ->
        :ok

      {:ok, row} ->
        deliver(row, opts)
        # Claim just one row at a time so an unstarted batch cannot lose its lease.
        drain(opts)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, reason} ->
        Logger.warning("outbox claim failed: #{inspect(reason)}")
        :ok
    end
  end

  defp deliver(
         %{id: id, kind: kind, payload: payload, attempts: attempts, claimed_at: claimed_at},
         opts
       ) do
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
      :ok -> mark_sent(id, claimed_at)
      {:error, reason} -> mark_retry(id, claimed_at, attempts, reason)
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
        LIMIT 1
        FOR UPDATE SKIP LOCKED
      )
      RETURNING id, kind, payload, attempts, claimed_at
      """
    )
    |> case do
      {:ok, %{rows: []}} -> {:ok, nil}

      {:ok, %{rows: [[id, kind, payload, attempts, claimed_at]]}} ->
        {:ok,
         %{
           id: id,
           kind: kind,
           payload: payload || %{},
           attempts: attempts,
           claimed_at: claimed_at
         }}

      other ->
        other
    end
  end

  defp mark_sent(id, claimed_at) do
    Repo.query(
      """
      UPDATE public.mithril_outbox
      SET status = 'sent', sent_at = now(), last_error = NULL
      WHERE id = $1::uuid AND status = 'sending' AND claimed_at = $2
      """,
      [DbUuid.dump!(id), claimed_at]
    )
  end

  defp mark_retry(id, claimed_at, attempts, reason) do
    error = reason |> inspect() |> String.slice(0, 200)

    if attempts >= @max_attempts or reason in [:missing_email, :payment_not_configured] do
      Repo.query(
        """
        UPDATE public.mithril_outbox
        SET status = 'failed', last_error = $2
        WHERE id = $1::uuid AND status = 'sending' AND claimed_at = $3
        """,
        [DbUuid.dump!(id), error, claimed_at]
      )
    else
      Repo.query(
        """
        UPDATE public.mithril_outbox
        SET status = 'pending',
            available_at = now() + make_interval(mins => $2),
            last_error = $3
        WHERE id = $1::uuid AND status = 'sending' AND claimed_at = $4
        """,
        [DbUuid.dump!(id), attempts, error, claimed_at]
      )
    end
  end
end
