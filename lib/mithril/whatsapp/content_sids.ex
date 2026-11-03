defmodule Mithril.WhatsApp.ContentSids do
  @moduledoc false

  @templates %{
    "application_rejected" => "HX09c7ad22b0ca92cd539ee8aeb192d47e",
    "request_more_info" => "HX78fd4eb7482d276a45e12e7db2db8065",
    "new_user_created" => "HXcbf6e1b15043366bdf2b93533e573254",
    "cleaner_assigned" => "HX1658bbc9404a734f86eee1a972a6b5c8",
    "booking_rescheduled" => "HX334c4009d26198d355be63420554a26d",
    "co_cleaner_invite" => "HX36a21746c8fc024fba2f8601a465e36d",
    "preferred_cleaner_invite" => "HXe04d60c419da7ca4df86711dd214e978",
    "phone_otp" => "HX0c13fa64693fc800d33ee2fe82d64c75"
  }

  @quick_replies %{
    yes_no: "HX94459b817d4508364b9ea383be3974d3",
    accept: "HX7c4c736e02d753ce38233fe15e73dbe4"
  }

  @doc "Content SID for a template that replaces a rejected or cleaner-worded copy."
  def template(name) when is_binary(name), do: Map.get(@templates, name)

  def quick_reply(kind) when is_atom(kind), do: Map.get(@quick_replies, kind)
end
