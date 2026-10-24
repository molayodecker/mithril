defmodule Mithril.DirectAssignmentNotify do
  @moduledoc """
  After a chosen worker's booking is paid, tell that worker on SMS and WhatsApp.

  The payment trigger already inserts the in-app `direct_assignment_offer`.
  This claims that row so WhatsApp and SMS go out once. A missing inbox row
  is inserted here so the worker still gets the in-app alert.
  """

  require Logger

  alias Mithril.Notifications
  alias Mithril.Repo

  @offer_title "You were selected for a job"
  @offer_message "You've been selected for a job. Accept it in the app before it is offered to other workers."

  @spec notify_chosen_worker(term()) :: :sent | :skipped
  def notify_chosen_worker(booking_id) when is_binary(booking_id) do
    case Ecto.UUID.dump(booking_id) do
      {:ok, booking_uuid} ->
        claim_and_send(booking_uuid, booking_id)

      :error ->
        :skipped
    end
  rescue
    error ->
      Logger.warning("direct assignment notification failed: #{Exception.message(error)}")
      :skipped
  end

  def notify_chosen_worker(_booking_id), do: :skipped

  defp claim_and_send(booking_uuid, booking_id) do
    case claim_offer(booking_uuid, booking_id) do
      {:send, context} ->
        Notifications.notify(context)
        :sent

      :skip ->
        :skipped
    end
  end

  defp claim_offer(booking_uuid, booking_id) do
    Repo.transaction(fn ->
      case load_offer(booking_uuid) do
        {:ok, offer} ->
          case claim_inbox(offer, booking_id) do
            :send -> offer_context(offer, booking_id)
            :skip -> Repo.rollback(:skip)
          end

        :miss ->
          Repo.rollback(:skip)
      end
    end)
    |> case do
      {:ok, context} -> {:send, context}
      _ -> :skip
    end
  end

  defp load_offer(booking_uuid) do
    case Repo.query(
           """
           SELECT cleaner_id, direct_assigned_cleaner_id, customer_id,
                  assignment_phase::text, lower(payment_status::text), cleaner_accepted_at,
                  address, scheduled_date::text, scheduled_time::text,
                  COALESCE(NULLIF(btrim(title), ''), 'Instaclean booking')
           FROM public.bookings
           WHERE id = $1
           FOR UPDATE
           """,
           [booking_uuid]
         ) do
      {:ok, %{rows: [row]}} ->
        if chosen_worker_offer?(row), do: {:ok, row_to_offer(row)}, else: :miss

      _ ->
        :miss
    end
  end

  defp chosen_worker_offer?([
         cleaner_id,
         direct_assigned_cleaner_id,
         _customer_id,
         assignment_phase,
         payment_status,
         cleaner_accepted_at
         | _
       ]) do
    payment_status == "paid" and is_nil(cleaner_accepted_at) and not is_nil(cleaner_id) and
      cleaner_id == direct_assigned_cleaner_id and assignment_phase in [nil, "exclusive"]
  end

  defp chosen_worker_offer?(_row), do: false

  defp row_to_offer([
         cleaner_id,
         _direct_assigned_cleaner_id,
         customer_id,
         _assignment_phase,
         _payment_status,
         _cleaner_accepted_at,
         address,
         scheduled_date,
         scheduled_time,
         service_name
       ]) do
    %{
      cleaner_id: cleaner_id,
      customer_id: customer_id,
      address: address || "",
      scheduled_date: scheduled_date || "",
      scheduled_time: clock(scheduled_time),
      service_name: service_name
    }
  end

  defp claim_inbox(offer, booking_id) do
    case Repo.query(
           """
           SELECT id, COALESCE(data->>'outbound_sent', '')
           FROM public.notifications
           WHERE user_id = $1
             AND type::text = 'direct_assignment_offer'
             AND (
               data->>'bookingId' = $2
               OR data->>'booking_id' = $2
             )
           ORDER BY created_at DESC NULLS LAST
           LIMIT 1
           FOR UPDATE
           """,
           [offer.cleaner_id, booking_id]
         ) do
      {:ok, %{rows: [[_notification_id, "true"]]}} ->
        :skip

      {:ok, %{rows: [[notification_id, _outbound_sent]]}} ->
        mark_outbound_sent(notification_id)
        :send

      {:ok, %{rows: []}} ->
        insert_inbox(offer, booking_id)
        :send

      {:error, error} ->
        Logger.warning("direct assignment inbox claim failed: #{inspect(error)}")
        :skip
    end
  end

  defp mark_outbound_sent(notification_id) do
    Repo.query!(
      """
      UPDATE public.notifications
      SET data = COALESCE(data, '{}'::jsonb) || '{"outbound_sent": true}'::jsonb
      WHERE id = $1
      """,
      [notification_id]
    )
  end

  defp insert_inbox(offer, booking_id) do
    Repo.query!(
      """
      INSERT INTO public.notifications (id, user_id, type, title, message, read, data)
      VALUES (
        $1, $2, 'direct_assignment_offer', $3, $4, false,
        jsonb_build_object(
          'booking_id', $5::text,
          'bookingId', $5::text,
          'type', 'direct_assignment_offer',
          'audience', 'cleaner',
          'assignment_phase', 'exclusive',
          'outbound_sent', true
        )
      )
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        offer.cleaner_id,
        @offer_title,
        @offer_message,
        booking_id
      ]
    )
  end

  defp offer_context(offer, booking_id) do
    %{
      send_notifications: true,
      recipient: :worker,
      kind: :direct_assignment_offer,
      booking_id: booking_id,
      customer: Notifications.load_party(encode_uuid(offer.customer_id)),
      worker: Notifications.load_party(encode_uuid(offer.cleaner_id)),
      address: offer.address,
      service_name: offer.service_name,
      dates: present_dates(offer.scheduled_date),
      scheduled_time: offer.scheduled_time
    }
  end

  defp present_dates(date) when is_binary(date) and date != "", do: [date]
  defp present_dates(_date), do: []

  defp clock(nil), do: ""

  defp clock(value) when is_binary(value) do
    value |> String.trim() |> String.slice(0, 5)
  end

  defp clock(_value), do: ""

  defp encode_uuid(nil), do: nil

  defp encode_uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
