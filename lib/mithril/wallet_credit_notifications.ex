defmodule Mithril.WalletCreditNotifications do
  @moduledoc """
  In-app notification and WhatsApp when money is added to a cleaner wallet.

  Job earnings and manual adds qualify. A credit that refunds a failed
  withdrawal does not. The inbox insert is what the existing notification
  trigger uses for the lock-screen push. WhatsApp uses the approved
  `service_update` template through send-notification.
  """

  require Logger

  alias Mithril.Notifications.SendNotification
  alias Mithril.Repo

  @title "Money added to your wallet"
  @batch_limit 50

  @spec run() :: :ok | {:error, term()}
  def run, do: run(whatsapp_sender: &send_whatsapp/1)

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) when is_list(opts) do
    sender = Keyword.get(opts, :whatsapp_sender, &send_whatsapp/1)

    case pending_credits() do
      {:ok, credits} ->
        Enum.each(credits, &deliver(&1, sender))
        :ok

      {:error, reason} ->
        Logger.warning("wallet credit notification lookup failed: #{inspect(reason)}")
        {:error, :database_unavailable}
    end
  end

  @spec notifiable_credit?(map()) :: boolean()
  def notifiable_credit?(credit) when is_map(credit) do
    type = credit |> Map.get(:type) |> to_string() |> String.trim() |> String.downcase()
    amount = Map.get(credit, :amount_subunit)
    withdrawal_id = Map.get(credit, :withdrawal_request_id)

    type == "credit" and is_nil(withdrawal_id) and is_integer(amount) and amount > 0
  end

  @spec amount_label(integer(), String.t() | nil) :: String.t()
  def amount_label(amount_subunit, currency) when is_integer(amount_subunit) do
    code =
      case currency && String.trim(to_string(currency)) do
        value when is_binary(value) and value != "" -> value
        _ -> "GHS"
      end

    negative = amount_subunit < 0
    minor = abs(amount_subunit)
    whole = div(minor, 100)
    cents = rem(minor, 100)
    sign = if negative, do: "-", else: ""

    "#{code} #{sign}#{group_thousands(whole)}.#{String.pad_leading(Integer.to_string(cents), 2, "0")}"
  end

  @spec message(integer(), String.t() | nil, String.t() | nil) :: String.t()
  def message(amount_subunit, currency, booking_id) do
    label = amount_label(amount_subunit, currency)

    if is_binary(booking_id) and String.trim(booking_id) != "" do
      "#{label} from a completed job was added to your wallet."
    else
      "#{label} was added to your Instaclean wallet."
    end
  end

  defp pending_credits do
    case Repo.query(
           """
           SELECT t.id::text,
                  w.user_id::text,
                  t.amount_subunit,
                  t.booking_id::text,
                  coalesce(nullif(btrim(w.currency), ''), 'GHS'),
                  nullif(btrim(u.phone), ''),
                  coalesce(profile.display_name, 'there')
           FROM public.wallet_transactions t
           JOIN public.wallets w ON w.id = t.wallet_id
           JOIN public.users u ON u.id = w.user_id
           LEFT JOIN LATERAL (
             SELECT coalesce(
                      nullif(btrim(p.fullname), ''),
                      nullif(btrim(p.firstname), ''),
                      'there'
                    ) AS display_name
             FROM public.profiles p
             WHERE p.id = u.id OR p.user_id = u.id
             ORDER BY (p.id = u.id) DESC
             LIMIT 1
           ) profile ON true
           WHERE lower(coalesce(t.type, '')) = 'credit'
             AND t.withdrawal_request_id IS NULL
             AND coalesce(t.amount_subunit, 0) > 0
             AND t.created_at >= (
               SELECT activated_at FROM public.wallet_credit_notification_settings WHERE id = true
             )
             AND (
               NOT EXISTS (
                 SELECT 1 FROM public.notifications n
                 WHERE n.user_id = w.user_id
                   AND n.dedupe_key = 'wallet_credit:' || t.id::text
               )
               OR (
                 EXISTS (
                   SELECT 1 FROM public.notifications n
                   WHERE n.user_id = w.user_id
                     AND n.dedupe_key = 'wallet_credit:' || t.id::text
                 )
                 AND (
                   NOT EXISTS (
                     SELECT 1 FROM public.wallet_credit_whatsapp_delivery d
                     WHERE d.transaction_id = t.id
                   )
                   OR EXISTS (
                     SELECT 1 FROM public.wallet_credit_whatsapp_delivery d
                     WHERE d.transaction_id = t.id
                       AND d.sent_at IS NULL
                       AND d.next_attempt_at <= now()
                   )
                 )
               )
             )
           ORDER BY
             CASE WHEN NOT EXISTS (
               SELECT 1 FROM public.notifications n
               WHERE n.user_id = w.user_id
                 AND n.dedupe_key = 'wallet_credit:' || t.id::text
             ) THEN 0 ELSE 1 END,
             t.created_at ASC NULLS LAST
           LIMIT $1
           """,
           [@batch_limit]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &credit_from_row/1)}
      {:error, error} -> {:error, error}
    end
  end

  defp credit_from_row([
         transaction_id,
         user_id,
         amount_subunit,
         booking_id,
         currency,
         phone,
         name
       ]) do
    %{
      transaction_id: transaction_id,
      user_id: user_id,
      amount_subunit: amount_subunit,
      booking_id: blank_to_nil(booking_id),
      currency: currency,
      phone: blank_to_nil(phone),
      name: blank_to_nil(name) || "there"
    }
  end

  defp deliver(credit, sender) do
    body = message(credit.amount_subunit, credit.currency, credit.booking_id)

    case insert_inbox(credit, body) do
      result when result in [:inserted, :duplicate] ->
        maybe_send_whatsapp(credit, body, sender)

      :error ->
        :ok
    end
  end

  # A lease prevents overlapping sweeps from sending the same WhatsApp.
  # The inbox and outbound delivery state are intentionally independent.
  defp maybe_send_whatsapp(credit, body, sender) do
    with {:ok, transaction_id} <- Ecto.UUID.dump(credit.transaction_id),
         {:ok, %{rows: [[_]]}} <-
           Repo.query(
             """
             INSERT INTO public.wallet_credit_whatsapp_delivery
               (transaction_id, next_attempt_at)
             VALUES ($1::uuid, now() + interval '5 minutes')
             ON CONFLICT (transaction_id) DO UPDATE
               SET next_attempt_at = now() + interval '5 minutes'
             WHERE wallet_credit_whatsapp_delivery.sent_at IS NULL
               AND wallet_credit_whatsapp_delivery.next_attempt_at <= now()
             RETURNING transaction_id
             """,
             [transaction_id]
           ) do
      result =
        try do
          sender.(Map.put(credit, :message, body))
        rescue
          error ->
            Logger.warning(
              "wallet credit WhatsApp sender crashed transaction=#{credit.transaction_id}: #{inspect(error)}"
            )

            :failed
        catch
          kind, reason ->
            Logger.warning(
              "wallet credit WhatsApp sender failed transaction=#{credit.transaction_id}: #{inspect({kind, reason})}"
            )

            :failed
        end

      if result in [:sent, :ok, :no_phone] or
           match?({:ok, %{"whatsappSent" => true}}, result) or
           match?({:ok, %{whatsappSent: true}}, result) do
        case Repo.query(
               """
               UPDATE public.wallet_credit_whatsapp_delivery
               SET sent_at = now()
               WHERE transaction_id = $1::uuid AND sent_at IS NULL
               """,
               [transaction_id]
             ) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.warning("wallet credit WhatsApp receipt failed: #{inspect(error)}")
        end
      end

      :ok
    else
      {:ok, %{rows: []}} ->
        :ok

      {:error, error} ->
        Logger.warning("wallet credit WhatsApp queue failed: #{inspect(error)}")
        :ok

      :error ->
        :ok
    end
  end

  defp insert_inbox(credit, body) do
    with {:ok, user_id} <- Ecto.UUID.dump(credit.user_id) do
      data =
        Jason.encode!(%{
          "type" => "wallet_credited",
          "screen" => "/(tabs)/wallet",
          "walletTransactionId" => credit.transaction_id,
          "amountSubunit" => credit.amount_subunit,
          "currency" => credit.currency
        })

      case Repo.query(
             """
             INSERT INTO public.notifications (
               user_id, type, title, message, read, dedupe_key, data
             ) VALUES (
               $1::uuid, 'wallet_credited', $2, $3, false, $4, $5::jsonb
             )
             ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL
             DO NOTHING
             RETURNING id
             """,
             [user_id, @title, body, "wallet_credit:#{credit.transaction_id}", data]
           ) do
        {:ok, %{num_rows: 1}} ->
          :inserted

        {:ok, %{num_rows: 0}} ->
          :duplicate

        {:error, error} ->
          Logger.warning(
            "wallet credit inbox insert failed transaction=#{credit.transaction_id}: #{inspect(error)}"
          )

          :error
      end
    else
      :error ->
        Logger.warning(
          "wallet credit notification skipped invalid user #{inspect(credit.user_id)}"
        )

        :error
    end
  end

  defp send_whatsapp(%{phone: nil}), do: :no_phone

  defp send_whatsapp(credit) do
    if SendNotification.configured?() do
      case SendNotification.deliver_raw(%{
             "template" => "service_update",
             "channel" => "whatsapp",
             "userId" => credit.user_id,
             "phone" => credit.phone,
             "messageType" => "wallet_credited",
             "idempotencyKey" => "wallet_credit:#{credit.transaction_id}",
             "variables" => %{"name" => credit.name, "message" => credit.message}
           }) do
        {:ok, %{"whatsappSent" => true}} ->
          :sent

        {:ok, %{whatsappSent: true}} ->
          :sent

        {:ok, _response} ->
          Logger.warning("wallet credit WhatsApp not confirmed transaction=#{credit.transaction_id}")
          :failed

        {:error, status, _body} ->
          Logger.warning(
            "wallet credit WhatsApp failed transaction=#{credit.transaction_id} status=#{status}"
          )

          :failed
      end
    else
      Logger.warning(
        "wallet credit WhatsApp skipped, send-notification is not configured transaction=#{credit.transaction_id}"
      )

      :skipped
    end
  end

  defp group_thousands(whole) when is_integer(whole) do
    whole
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil
end
