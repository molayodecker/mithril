defmodule Mithril.Workers.AdminNotificationDelivery do
  @moduledoc false

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: 3600, keys: [:batch_id, :channel, :phone]]

  alias Mithril.Auth.SMS
  alias Mithril.DirectAdminWhatsApp

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => "sms", "phone" => phone, "body" => body}}) do
    case SMS.send_message(phone, body) do
      :ok ->
        :ok

      {:error, reason} when reason in [:sms_not_configured, :invalid_phone, :invalid_message] ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{
        args:
          %{
            "channel" => "whatsapp",
            "admin_user_id" => admin_user_id,
            "phone" => phone,
            "body" => body
          } = args
      }) do
    with {:ok, admin_uid} <- Ecto.UUID.dump(admin_user_id) do
      case DirectAdminWhatsApp.deliver_as_staff(admin_uid, %{
             "phoneE164" => phone,
             "body" => body,
             "businessPhoneE164" => args["from"]
           }) do
        {:ok, _} ->
          :ok

        {:error, reason} when reason in [:twilio_not_configured, :invalid_request] ->
          :discard

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> :discard
    end
  end

  def perform(_job), do: :discard
end
