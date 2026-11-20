defmodule Mithril.WhatsApp.SessionFollowUpTemplateTest do
  use ExUnit.Case, async: true

  alias Mithril.WhatsApp.SessionFollowUpTemplate

  test "a customer reply in the last day can take a normal message" do
    now = ~U[2026-11-20 15:00:00Z]
    recent = DateTime.add(now, -23 * 60 * 60, :second)

    assert SessionFollowUpTemplate.within_window?(recent, now)
    refute SessionFollowUpTemplate.within_window?(nil, now)
    refute SessionFollowUpTemplate.within_window?(DateTime.add(now, -24 * 60 * 60, :second), now)
  end

  test "the follow-up keeps the staff message inside the approved wording" do
    assert SessionFollowUpTemplate.variables("Ama Mensah", "Your cleaner arrives at 9.") ==
             %{"1" => "Ama", "2" => "Your cleaner arrives at 9."}

    assert SessionFollowUpTemplate.render("Ama Mensah", "Your cleaner arrives at 9.") ==
             "Hello Ama, Instaclean has a message for you. Your cleaner arrives at 9. Reply to this message and we will continue here."
  end
  test "oversized template messages fail rather than losing their suffix" do
    accepted = String.duplicate("a", 1024)
    rejected = accepted <> "final instructions"

    assert :ok = SessionFollowUpTemplate.validate_message(accepted)
    assert {:error, :invalid_request} = SessionFollowUpTemplate.validate_message(rejected)
    assert SessionFollowUpTemplate.variables("Ama", rejected)["2"] == rejected
    assert SessionFollowUpTemplate.render("Ama", rejected) =~ rejected
  end

end
