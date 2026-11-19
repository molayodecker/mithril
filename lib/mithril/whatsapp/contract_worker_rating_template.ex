defmodule Mithril.WhatsApp.ContractWorkerRatingTemplate do
  @moduledoc """
  WhatsApp template that asks a contract client to rate their worker.

  The button opens `{DIRECT_PUBLIC_URL}/rate/{{3}}`, where `{{3}}` is the
  unguessable token. The page does not require a sign-in.

  Set `TWILIO_TEMPLATE_CONTRACT_WORKER_RATING` to the approved Content SID
  `instaclean_contract_worker_rating`. The first send can create and submit
  that template. Until WhatsApp approves it, delivery falls back to a session
  message that includes the same link.
  """

  alias Mithril.DirectAdminWhatsApp
  alias Mithril.WhatsApp.ContentTemplate
  alias Mithril.WhatsApp.PaymentTemplate

  @name "instaclean_contract_worker_rating"
  @env_key :twilio_template_contract_worker_rating
  @button "Rate your worker"

  def name, do: @name

  def body do
    "Hello {{1}}, how is {{2}} doing? Please rate them so we can keep the right person with you."
  end

  def readable(name, worker, url) do
    "Hello #{clip(name, 60, "there")}, how is #{clip(worker, 40, "your worker")} doing? Please rate them so we can keep the right person with you. #{url}"
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{
        "1" => "Ama",
        "2" => "Efua Mensah",
        "3" => "a1b2c3d4e5f6789012345678abcdef0123456789abcdef0123456789abcdef01"
      },
      "types" => %{
        "twilio/call-to-action" => %{
          "body" => body(),
          "actions" => [
            %{
              "type" => "URL",
              "title" => @button,
              "url" => "#{public_base()}/rate/{{3}}"
            }
          ]
        }
      }
    }
  end

  def variables(name, worker, token) do
    %{
      "1" => clip(name, 60, "there"),
      "2" => clip(worker, 40, "your worker"),
      "3" => token
    }
  end

  def ensure do
    ContentTemplate.ensure(@name, @env_key, definition())
  end

  def deliver(admin_uid, phone, name, worker, token)
      when is_binary(admin_uid) and is_binary(phone) and is_binary(name) and
             is_binary(worker) and is_binary(token) do
    url = "#{public_base()}/rate/#{token}"
    params = %{"phoneE164" => phone, "body" => readable(name, worker, url)}

    case sid() do
      content when is_binary(content) ->
        case DirectAdminWhatsApp.deliver_content_as_staff(
               admin_uid,
               params,
               content,
               variables(name, worker, token)
             ) do
          {:ok, _} -> :ok
          {:error, :template_rejected} -> session(admin_uid, params)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        session(admin_uid, params)
    end
  end

  def public_base, do: PaymentTemplate.public_base()

  defp sid do
    resolve_sid(
      Application.get_env(:mithril, :google_review_ensure_template, false),
      fn -> ContentTemplate.ensure(@name, @env_key, definition()) end,
      fn -> ContentTemplate.content_sid(@name, @env_key) end
    )
  end

  defp resolve_sid(true, ensure, _lookup) when is_function(ensure, 0) do
    case ensure.() do
      {:ok, content} when is_binary(content) -> content
      _ -> nil
    end
  end

  defp resolve_sid(false, _ensure, lookup) when is_function(lookup, 0), do: lookup.()

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
