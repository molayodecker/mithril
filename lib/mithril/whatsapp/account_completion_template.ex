defmodule Mithril.WhatsApp.AccountCompletionTemplate do
  @moduledoc """
  WhatsApp template promising GHS 25 when an unfinished account is completed.

  Set `TWILIO_TEMPLATE_ACCOUNT_COMPLETION` to the approved Twilio Content SID
  `instaclean_complete_account_bonus`. Until WhatsApp approves that template,
  delivery falls back to a session message.
  """

  alias Mithril.DirectAdminWhatsApp
  alias Mithril.WhatsApp.ContentTemplate

  @name "instaclean_complete_account_bonus"
  @env_key :twilio_template_account_completion

  def name, do: @name

  def body do
    "Hello {{1}}, finish your Instaclean account and we will add GHS 25 to your wallet. You can withdraw it after your account is complete."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{"1" => "Ama"},
      "types" => %{
        "twilio/text" => %{
          "body" => body()
        }
      }
    }
  end

  def variables(name) do
    %{"1" => clip(name, 60, "there")}
  end

  def readable(name) do
    filled = variables(name)

    "Hello #{filled["1"]}, finish your Instaclean account and we will add GHS 25 to your wallet. You can withdraw it after your account is complete."
  end

  def content_sid do
    ContentTemplate.content_sid(@name, @env_key)
  end

  def ensure do
    ContentTemplate.ensure(@name, @env_key, definition())
  end

  def deliver(admin_uid, phone, name) when is_binary(admin_uid) and is_binary(phone) do
    params = %{"phoneE164" => phone, "body" => readable(name)}

    with sid when is_binary(sid) <- content_sid(),
         variables <- variables(name) do
      case DirectAdminWhatsApp.deliver_content_as_staff(admin_uid, params, sid, variables) do
        {:ok, _} -> :ok
        {:error, :template_rejected} -> session(admin_uid, params)
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> session(admin_uid, params)
    end
  end

  defp session(admin_uid, params) do
    case DirectAdminWhatsApp.deliver_as_staff(admin_uid, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clip(value, max, fallback) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/[{}]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, max)

    if cleaned == "", do: fallback, else: cleaned
  end
end
