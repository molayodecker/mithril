defmodule Mithril.Notifications.TemplatesTest do
  use ExUnit.Case, async: true

  alias Mithril.Notifications.Templates

  test "co-worker invite copy does not say co-cleaner" do
    body =
      Templates.body("co_cleaner_invite", %{
        "inviterName" => "Ama",
        "inviteUrl" => "https://tryinstaclean.com/api/co-cleaner-invite?token=abc",
        "expiresAt" => "2 Nov 2026"
      })

    assert Templates.subject("co_cleaner_invite") =~ "join a team"
    assert body =~ "co-worker"
    assert body =~ "Ama"
    refute body =~ "as a co-cleaner"
    refute body =~ "Co-cleaner invitation"
  end

  test "preferred worker invite and signup verification have their own subjects" do
    assert Templates.subject("preferred_cleaner_invite") =~ "preferred worker"
    assert Templates.subject("signup_verification") == "Verify your Instaclean account"

    assert Templates.body("signup_verification", %{
             "confirmationUrl" => "https://example.test/confirm"
           }) =~
             "https://example.test/confirm"

    assert Templates.subject("booking_cancelled") =~ "cancelled"
    assert Templates.subject("service_update") =~ "service update"
  end
end
