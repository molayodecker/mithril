defmodule Mithril.WhatsApp.Recruitment.Rosie do
  @moduledoc false

  @name "Rosie"
  @linktree "https://linktr.ee/instacleanapp"
  @onelink "https://onelink.to/ew8zar?&dev=macos&ref="
  @android "https://play.google.com/store/apps/details?id=com.tryinstaclean&pli=1"
  @ios "https://apps.apple.com/us/app/instaclean-verified-cleaners/id6759078936"
  @support_phone "0544415766"

  def maybe_reply(message, cmd, app_url, current_step) do
    cond do
      cmd == "HELP" -> help()
      cmd == "WEB" -> links(app_url)
      cmd != nil -> nil
      current_step != "awaiting_apply" -> nil
      true -> faq(message, app_url)
    end
  end

  def help do
    "My name is #{@name} and I'm here to assist you.\n\n" <>
      "Do you want to apply as a cleaner? Reply APPLY.\n\n" <>
      "You can also ask me about:\n" <>
      "- Instaclean services\n" <>
      "- Promotions\n" <>
      "- App download links\n" <>
      "- How to book a cleaner\n" <>
      "- Cleaner applications\n" <>
      "- Website and support"
  end

  def links(app_url) do
    "Here are the main Instaclean links:\n\n" <>
      "Website:\n#{app_url}\n\n" <>
      "All links:\n#{@linktree}\n\n" <>
      "Download the app:\n#{@onelink}\n\n" <>
      "Android:\n#{@android}\n\n" <>
      "iPhone:\n#{@ios}"
  end

  defp faq(message, app_url) do
    text = normalize(message)

    cond do
      includes_any?(
        text,
        ~w(download app android iphone ios install link onelink) ++ ["play store", "app store"]
      ) ->
        "You can download Instaclean here:\n\n" <>
          "All app links:\n#{@onelink}\n\n" <>
          "Android:\n#{@android}\n\n" <>
          "iPhone:\n#{@ios}\n\n" <>
          "You can also visit:\n#{@linktree}"

      includes_any?(text, ~w(promotion promotions promo discount offer free coupon deal)) ->
        "Promotions may change from time to time.\n\n" <>
          "To see current Instaclean promotions, please check the app, website, or Linktree:\n\n" <>
          "#{app_url}\n#{@linktree}\n\n" <>
          "If you are a new customer, check the booking screen for any welcome offers before payment."

      includes_any?(
        text,
        ~w(apply application job work join recruitment) ++ ["cleaner job", "become a cleaner"]
      ) ->
        "You can apply to become an Instaclean cleaner right here on WhatsApp.\n\n" <>
          "Reply APPLY to start.\n\n" <>
          "You can also apply on the website:\n#{app_url}/join-as-cleaner"

      includes_any?(text, ~w(support contact phone call whatsapp manager)) ->
        "You can reach Instaclean support through our website or links here:\n\n" <>
          "#{app_url}\n#{@linktree}\n\n" <>
          "Operations support phone: #{@support_phone}"

      includes_any?(
        text,
        ~w(service services cleaning book booking instaclean) ++
            [
              "home cleaning",
              "house cleaning",
              "book a cleaner",
              "who are you",
              "who is instaclean",
              "what is instaclean",
              "about instaclean",
              "about you"
            ]
      ) ->
        "Instaclean helps customers book trusted home services in Ghana, including cleaning and related household services.\n\n" <>
          "You can book through the app or website:\n\n" <>
          "#{app_url}\n#{@linktree}\n\n" <>
          "If you want to apply as a cleaner, reply APPLY."

      true ->
        "My name is #{@name} and I'm here to assist you with Instaclean.\n\n" <>
          "You can ask me about app downloads, promotions, services, booking, or cleaner applications.\n\n" <>
          "To apply as a cleaner, reply APPLY.\n\n" <>
          "Website:\n#{app_url}\n\n" <>
          "All links:\n#{@linktree}"
    end
  end

  defp normalize(message) do
    message
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
  end

  defp includes_any?(text, words) do
    Enum.any?(words, &String.contains?(text, &1))
  end
end
