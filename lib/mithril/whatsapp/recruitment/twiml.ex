defmodule Mithril.WhatsApp.Recruitment.Twiml do
  @moduledoc false

  @text_footer "\n\nReply here to continue on WhatsApp.\n\nPrefer the website? Reply WEB anytime."
  @menu_footer "\n\nReply with the number to continue on WhatsApp.\n\nPrefer the website? Reply WEB anytime."

  def xml(:empty), do: ~s(<?xml version="1.0" encoding="UTF-8"?><Response></Response>)

  def xml({:plain, message}), do: wrap(message)

  def xml({:text, message}), do: wrap(with_text_footer(message))

  def xml({:menu, message}), do: wrap(with_menu_footer(message))

  def xml({:multi, message, max_option}) do
    wrap(with_multi_footer(message, max_option))
  end

  def xml({:quick, reply}) do
    wrap(quick_fallback(reply))
  end

  def with_text_footer(message) do
    if String.contains?(message, "Reply WEB anytime"), do: message, else: message <> @text_footer
  end

  def with_menu_footer(message) do
    if String.contains?(message, "Reply WEB anytime"), do: message, else: message <> @menu_footer
  end

  def with_multi_footer(message, max_option) do
    if String.contains?(message, "Reply WEB anytime") do
      message
    else
      message <> multi_select_footer(max_option)
    end
  end

  def strip_footers(message) do
    message
    |> maybe_strip(@menu_footer)
    |> maybe_strip(@text_footer)
    |> String.trim_trailing()
  end

  def quick_fallback(%{fallback: fallback}) when is_binary(fallback) and fallback != "" do
    with_menu_footer(strip_footers(fallback))
  end

  def quick_fallback(%{message: message, buttons: buttons}) do
    stripped = strip_footers(message)

    lines =
      buttons
      |> Enum.take(3)
      |> Enum.map(fn %{id: id, title: title} -> "• #{title}: reply #{id}" end)
      |> Enum.join("\n")

    if lines == "" do
      with_text_footer(stripped)
    else
      with_menu_footer("#{stripped}\n\n#{lines}")
    end
  end

  def content_body(message) do
    stripped = strip_footers(message)

    if String.length(stripped) <= 3600 do
      stripped
    else
      String.slice(stripped, 0, 3599) <> "…"
    end
  end

  defp multi_select_footer(max_option) do
    example =
      cond do
        max_option >= 5 -> "1, 3, 5"
        max_option >= 3 -> "1, 3"
        true -> "1, 2"
      end

    "\n\nReply with numbers separated by commas, or reply ALL to pick every option.\nExample: #{example}" <>
      @text_footer
  end

  defp maybe_strip(message, suffix) do
    if String.ends_with?(message, suffix) do
      String.slice(message, 0, String.length(message) - String.length(suffix))
    else
      message
    end
  end

  defp wrap(message) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Message>#{xml_escape(message)}</Message>
    </Response>
    """
  end

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
