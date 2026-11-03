defmodule Mithril.Notifications.Templates do
  @moduledoc false

  @doc "Subject for a product email, or nil when this module does not own the template."
  def subject("application_rejected"), do: "Your Instaclean application update"
  def subject("request_more_info"), do: "Action required – your Instaclean application"
  def subject("new_user_created"), do: "Welcome to Instaclean"
  def subject("signup_verification"), do: "Verify your Instaclean account"
  def subject("cleaner_application_submitted"), do: "Application received – Instaclean"
  def subject("booking_cancelled"), do: "Booking cancelled – Instaclean"
  def subject("booking_rescheduled"), do: "Booking rescheduled – Instaclean"
  def subject("co_cleaner_invite"), do: "You're invited to join a team on Instaclean"

  def subject("preferred_cleaner_invite"),
    do: "You're invited to be a preferred worker on Instaclean"

  def subject("payout_name_mismatch_report"), do: "Payout name mismatch – compliance review"
  def subject("payout_name_mismatch_user"), do: "Your payout details need review – Instaclean"
  def subject("service_update"), do: "Instaclean service update"
  def subject(_template), do: nil

  @doc "Plain-text body, or nil when this module does not own the template."
  def body("application_rejected", variables) do
    name = present(variables["name"]) || "there"
    feedback = present(variables["feedback"])
    detail = if feedback, do: " Feedback: #{feedback}", else: ""

    "Hi #{name}, we are unable to approve your Instaclean application at this time.#{detail} You can resubmit with updates anytime."
  end

  def body("request_more_info", variables) do
    name = present(variables["name"]) || "there"
    feedback = present(variables["feedback"]) || "more information"

    "Hi #{name}, we need the following before we can continue your Instaclean application: #{feedback}"
  end

  def body("new_user_created", variables) do
    name = present(variables["name"]) || "there"
    "Welcome to Instaclean, #{name}. Your account is ready."
  end

  def body("signup_verification", variables) do
    name = present(variables["name"]) || "there"
    url = present(variables["confirmationUrl"]) || ""
    "Hi #{name}, verify your email address to finish setting up Instaclean: #{url}"
  end

  def body("cleaner_application_submitted", variables) do
    name = present(variables["name"]) || "there"
    "Hi #{name}, we received your Instaclean application. We will review it and contact you soon."
  end

  def body("booking_cancelled", variables) do
    name = present(variables["name"]) || "there"
    booking = present(variables["bookingId"])
    message = present(variables["message"]) || "Your booking was cancelled."
    prefix = if booking, do: "Booking #{booking}: ", else: ""
    "Hi #{name}, #{prefix}#{message}"
  end

  def body("booking_rescheduled", variables) do
    name = present(variables["name"]) || "there"
    booking = present(variables["bookingId"])
    message = present(variables["message"]) || "Your booking was rescheduled."
    new_date = present(variables["date"]) || present(variables["newDate"])
    old_date = present(variables["oldDate"])

    when_text =
      cond do
        old_date && new_date -> " Previous time: #{old_date}. New time: #{new_date}."
        new_date -> " New time: #{new_date}."
        true -> ""
      end

    prefix = if booking, do: "Booking #{booking}: ", else: ""
    "Hi #{name}, #{prefix}#{message}#{when_text}"
  end

  def body("co_cleaner_invite", variables) do
    inviter = present(variables["inviterName"]) || "A teammate"
    url = present(variables["inviteUrl"]) || ""
    expires = present(variables["expiresAt"]) || "30 days"

    "#{inviter} invited you to join their Instaclean team as a co-worker. Your lead manages the team. Co-workers cannot accept marketplace jobs through this link. Open the invite: #{url} (expires #{expires})."
  end

  def body("preferred_cleaner_invite", variables) do
    inviter = present(variables["inviterName"]) || "A customer"
    url = present(variables["inviteUrl"]) || ""
    expires = present(variables["expiresAt"]) || "30 days"

    "#{inviter} invited you to be a preferred worker on Instaclean. Accept in the app: #{url} (expires #{expires})."
  end

  def body("payout_name_mismatch_report", variables) do
    user_id = present(variables["userId"]) || "unknown"
    profile = present(variables["profileName"]) || "unknown"
    payout = present(variables["payoutAccountName"]) || "unknown"
    payout_type = present(variables["payoutType"]) || "unknown"

    "Payout name mismatch for user #{user_id}. Profile name: #{profile}. Payout account name: #{payout}. Payout type: #{payout_type}."
  end

  def body("payout_name_mismatch_user", variables) do
    name = present(variables["name"]) || "there"
    payout = present(variables["payoutAccountName"]) || "your payout account"
    profile = present(variables["profileName"]) || "your profile"
    support = present(variables["supportEmail"]) || "support@tryinstaclean.com"

    "Hi #{name}, the name on your payout account (#{payout}) does not match your profile name (#{profile}). Payouts may be delayed until this is reviewed. Contact #{support} if you believe this is a mistake."
  end

  def body("service_update", variables) do
    name = present(variables["name"]) || "there"
    message = present(variables["message"]) || "You have a service update in Instaclean."
    "Hi #{name}, #{message}"
  end

  def body(_template, _variables), do: nil

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_value), do: nil
end
