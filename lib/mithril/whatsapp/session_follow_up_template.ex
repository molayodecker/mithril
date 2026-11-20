defmodule Mithril.WhatsApp.SessionFollowUpTemplate do
  @moduledoc """
  Utility template for a staff WhatsApp message sent more than 24 hours after
  the customer's last reply. A free-form message outside that window is rejected
  by WhatsApp.
  """

  alias Mithril.WhatsApp.ContentTemplate

  @name "instaclean_session_follow_up"
  @env_key :twilio_template_session_follow_up
  @window_seconds 24 * 60 * 60

  def name, do: @name

  def body do
    "Hello {{1}}, Instaclean has a message for you. {{2}} Reply to this message and we will continue here."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{"1" => "Ama", "2" => "Your visit is confirmed for tomorrow morning."},
      "types" => %{
        "twilio/text" => %{
          "body" => body()
        }
      }
    }
  end

  def within_window?(nil, _now), do: false

  def within_window?(%DateTime{} = last_inbound, %DateTime{} = now) do
    DateTime.diff(now, last_inbound, :second) < @window_seconds
  end

  def variables(name, message) do
    %{"1" => clip_name(name), "2" => clip_message(message)}
  end

  def render(name, message) do
    "Hello #{clip_name(name)}, Instaclean has a message for you. #{clip_message(message)} Reply to this message and we will continue here."
  end

  def ensure, do: content_sid()

  def content_sid do
    case Application.get_env(:mithril, @env_key) do
      sid when is_binary(sid) and sid != "" ->
        {:ok, String.trim(sid)}

      _ ->
        ContentTemplate.ensure(@name, @env_key, definition())
    end
  end

  defp clip_name(value) when is_binary(value) do
    name =
      value
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> to_string()
      |> String.replace(~r/[^\p{L}\p{N}'-]/u, "")
      |> String.slice(0, 40)

    if name == "" do
      "there"
    else
      name
    end
  end

  defp clip_name(_), do: "there"

  defp clip_message(value) when is_binary(value) do
    message =
      value
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, 1024)

    if message == "" do
      "We wanted to follow up with you."
    else
      message
    end
  end

  defp clip_message(_), do: "We wanted to follow up with you."
end
