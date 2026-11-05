defmodule Mithril.WhatsApp.GoogleReviewTemplate do
  @moduledoc """
  WhatsApp template that asks a customer to review Instaclean on Google.

  The button opens https://g.page/r/CZpfgtrjgJuTEBM/review. Set
  `TWILIO_TEMPLATE_GOOGLE_REVIEW` to the approved Content SID
  `instaclean_google_review`. The first send can create and submit that
  template. Until WhatsApp approves it, delivery falls back to a session
  message that includes the same link.
  """

  alias Mithril.DirectAdminWhatsApp
  alias Mithril.GoogleReview
  alias Mithril.WhatsApp.ContentTemplate

  @name "instaclean_google_review"
  @env_key :twilio_template_google_review
  @button "Review on Google"

  def name, do: @name

  def body do
    "Hello {{1}}, thank you for choosing Instaclean. If the work was good, a Google review helps other customers find us."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{"1" => "Ama"},
      "types" => %{
        "twilio/call-to-action" => %{
          "body" => body(),
          "actions" => [
            %{
              "type" => "URL",
              "title" => @button,
              "url" => GoogleReview.url()
            }
          ]
        }
      }
    }
  end

  def variables(name) do
    %{"1" => clip(name, 60, "there")}
  end

  def ensure do
    ContentTemplate.ensure(@name, @env_key, definition())
  end

  def deliver(admin_uid, phone, name)
      when is_binary(admin_uid) and is_binary(phone) and is_binary(name) do
    params = %{"phoneE164" => phone, "body" => GoogleReview.session_message(name)}

    case sid() do
      content when is_binary(content) ->
        case DirectAdminWhatsApp.deliver_content_as_staff(
               admin_uid,
               params,
               content,
               variables(name)
             ) do
          {:ok, _} -> :ok
          {:error, :template_rejected} -> session(admin_uid, params)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        session(admin_uid, params)
    end
  end

  defp sid do
    ContentTemplate.content_sid(@name, @env_key) || created_sid()
  end

  defp created_sid do
    if Application.get_env(:mithril, :google_review_ensure_template, false) do
      case ContentTemplate.ensure(@name, @env_key, definition()) do
        {:ok, content} when is_binary(content) -> content
        _ -> nil
      end
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
