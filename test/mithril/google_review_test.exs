defmodule Mithril.GoogleReviewTest do
  use ExUnit.Case, async: false

  alias Mithril.GoogleReview
  alias Mithril.WhatsApp.GoogleReviewTemplate

  test "session message and email both carry the Google review link" do
    assert GoogleReview.session_message("Ama") =~
             "Hello Ama, thank you for choosing Instaclean."

    assert GoogleReview.session_message("Ama") =~ GoogleReview.url()

    message = GoogleReview.email("Ama <script>")
    assert message.subject == "Would you review Instaclean on Google?"
    assert message.text =~ GoogleReview.url()
    assert message.html =~ "Review us on Google"
    assert message.html =~ GoogleReview.url()
    assert message.html =~ "Ama &lt;script&gt;"
    refute message.html =~ "<script>"
  end

  test "a blank name is greeted as there" do
    assert GoogleReview.greeting("  ") == "there"
    assert GoogleReview.session_message(nil) =~ "Hello there,"
  end

  test "facebook opens Messenger when an app id is configured" do
    previous = Application.get_env(:mithril, :facebook_app_id)

    on_exit(fn ->
      if is_binary(previous) do
        Application.put_env(:mithril, :facebook_app_id, previous)
      else
        Application.delete_env(:mithril, :facebook_app_id)
      end
    end)

    Application.put_env(:mithril, :facebook_app_id, "1234567890")
    url = GoogleReview.facebook_url()
    assert url =~ "https://www.facebook.com/dialog/send?"
    assert url =~ "app_id=1234567890"
    assert url =~ URI.encode_www_form(GoogleReview.url())
    refute url =~ "secret"

    Application.delete_env(:mithril, :facebook_app_id)
    share = GoogleReview.facebook_url()
    assert share =~ "https://www.facebook.com/sharer/sharer.php?u="
    assert share =~ URI.encode_www_form(GoogleReview.url())
  end

  test "automatic provisioning retries approval instead of trusting a partially created SID" do
    ensure = fn ->
      send(self(), :ensure_called)
      {:error, :approval_unavailable}
    end
    lookup = fn ->
      send(self(), :lookup_called)
      "HXstale"
    end

    assert GoogleReviewTemplate.resolve_sid(true, ensure, lookup) == nil
    assert_received :ensure_called
    refute_received :lookup_called

    assert GoogleReviewTemplate.resolve_sid(false, ensure, lookup) == "HXstale"
    assert_received :lookup_called
  end

  test "automatic provisioning uses the approved or submitted SID" do
    ensure = fn -> {:ok, "HXsubmitted"} end
    assert GoogleReviewTemplate.resolve_sid(true, ensure, fn -> flunk("must not skip ensure") end) ==
             "HXsubmitted"
  end

  test "the WhatsApp template button is the static Google review link" do
    definition = GoogleReviewTemplate.definition()
    [action] = definition["types"]["twilio/call-to-action"]["actions"]

    assert action["title"] == "Review on Google"
    assert action["url"] == GoogleReview.url()
    refute action["url"] =~ "{{"
    assert definition["types"]["twilio/call-to-action"]["body"] =~ "{{1}}"
    assert GoogleReviewTemplate.variables("  Ama\nMensah  ") == %{"1" => "Ama Mensah"}
  end
end
