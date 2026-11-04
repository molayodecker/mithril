defmodule Mithril.WhatsApp.WorkerAddedTemplate do
  @moduledoc """
  WhatsApp template for a worker added to a contract.

  Set `TWILIO_TEMPLATE_WORKER_ADDED` to the approved Twilio Content SID
  `instaclean_worker_added`. Until WhatsApp approves that template,
  delivery falls back to a session message.
  """

  alias Mithril.DirectAdminWhatsApp
  alias Mithril.WhatsApp.ContentTemplate

  @name "instaclean_worker_added"
  @env_key :twilio_template_worker_added

  def name, do: @name

  def body do
    "Hello {{1}}, Instaclean has added you as {{2}} for {{3}}. Open the Instaclean app to see your assignment."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{
        "1" => "Ama Owusu",
        "2" => "Househelp",
        "3" => "Kofi Mensah Holdings"
      },
      "types" => %{
        "twilio/text" => %{
          "body" => body()
        }
      }
    }
  end

  def variables(%{"workerName" => name, "roleLabel" => role, "clientName" => client}) do
    %{
      "1" => clip(name, 60, "there"),
      "2" => clip(role, 40, "a worker"),
      "3" => clip(client, 80, "a client")
    }
  end

  def readable(name, role, client) do
    filled = variables(%{"workerName" => name, "roleLabel" => role, "clientName" => client})

    "Hello #{filled["1"]}, Instaclean has added you as #{filled["2"]} for #{filled["3"]}. Open the Instaclean app to see your assignment."
  end

  def content_sid do
    ContentTemplate.content_sid(@name, @env_key)
  end

  def ensure do
    ContentTemplate.ensure(@name, @env_key, definition())
  end

  def deliver(admin_uid, phone, name, role, client)
      when is_binary(admin_uid) and is_binary(phone) do
    params = %{"phoneE164" => phone, "body" => readable(name, role, client)}

    with sid when is_binary(sid) <- content_sid(),
         variables <-
           variables(%{"workerName" => name, "roleLabel" => role, "clientName" => client}) do
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
