defmodule Mithril.Notifications.MessagePush do
  @moduledoc false

  require Logger

  alias Mithril.DbUuid
  alias Mithril.Notifications.InboxPush
  alias Mithril.Repo

  @spec deliver(map(), keyword()) :: :ok | {:error, term()}
  def deliver(payload, opts \\ []) when is_map(payload) do
    message_id = text(payload, "message_id")

    if message_id do
      case load_message(message_id) do
        {:ok, message} ->
          send_to_recipient(message, opts)

        :missing ->
          :ok
      end
    else
      :ok
    end
  end

  defp send_to_recipient(message, opts) do
    preview = preview(message.content)

    case Repo.query(
           """
           INSERT INTO public.notifications (user_id, type, title, message, read, data, dedupe_key)
           VALUES (
             $1::uuid,
             'new_message',
             'New message',
             $2,
             false,
             jsonb_build_object(
               'type', 'new_message',
               'conversationId', $3::text,
               'conversation_id', $3::text,
               'messageId', $4::text
             ),
             $5
           )
           ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
           """,
           [
             DbUuid.dump!(message.recipient_id),
             preview,
             message.conversation_id,
             message.message_id,
             "new_message:" <> message.message_id
           ]
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("new message inbox insert failed: #{inspect(reason)}")
    end

    InboxPush.deliver(
      %{
        "user_id" => message.recipient_id,
        "title" => "New message",
        "body" => preview,
        "type" => "new_message",
        "data" => %{
          "type" => "new_message",
          "conversationId" => message.conversation_id,
          "conversation_id" => message.conversation_id,
          "messageId" => message.message_id
        }
      },
      opts
    )
  end

  defp load_message(message_id) do
    case Repo.query(
           """
           SELECT m.id::text,
                  m.conversation_id::text,
                  m.sender_id::text,
                  m.content,
                  c.customer_id::text,
                  c.cleaner_id::text
           FROM public.messages m
           JOIN public.conversations c ON c.id = m.conversation_id
           WHERE m.id = $1::uuid
           """,
           [DbUuid.dump!(message_id)]
         ) do
      {:ok,
       %{
         rows: [
           [id, conversation_id, sender_id, content, customer_id, cleaner_id]
         ]
       }} ->
        recipient_id =
          cond do
            sender_id == customer_id -> cleaner_id
            sender_id == cleaner_id -> customer_id
            true -> nil
          end

        if is_binary(recipient_id) and recipient_id != "" do
          {:ok,
           %{
             message_id: id,
             conversation_id: conversation_id,
             recipient_id: recipient_id,
             content: content || ""
           }}
        else
          :missing
        end

      _ ->
        :missing
    end
  end

  defp preview(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" -> "You have a new message."
      String.length(trimmed) > 140 -> String.slice(trimmed, 0, 140)
      true -> trimmed
    end
  end

  defp preview(_content), do: "You have a new message."

  defp text(map, key) do
    value = Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
    if is_binary(value) and String.trim(value) != "", do: String.trim(value), else: nil
  rescue
    ArgumentError -> nil
  end
end
