defmodule Mithril.MobileFunctions do
  @moduledoc false

  alias Mithril.MobileFunctions.CancelSubscription
  alias Mithril.MobileFunctions.ClaimJob
  alias Mithril.MobileFunctions.ConnectPropertyCalendar
  alias Mithril.MobileFunctions.CreateJobAndNotify
  alias Mithril.MobileFunctions.DeletePropertyMedia
  alias Mithril.MobileFunctions.NotifyBookingRescheduled
  alias Mithril.MobileFunctions.NotifyPaymentFailureOps
  alias Mithril.MobileFunctions.Paystack
  alias Mithril.MobileFunctions.RankCleanersWithAi
  alias Mithril.MobileFunctions.RequestDataExport
  alias Mithril.MobileFunctions.SendAppNotification
  alias Mithril.MobileFunctions.SumsubToken
  alias Mithril.MobileFunctions.SyncSumsubReview
  alias Mithril.MobileFunctions.Timezone
  alias Mithril.MobileFunctions.UberTransportationReleaseGate
  alias Mithril.MobileFunctions.UberTripEstimate

  @spec invoke(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(_user_id, name, _body)
      when name in ["fetch-otp-delivery-token", "resend-otp-via-channel", "send-notification"] do
    {:error, :forbidden}
  end

  def invoke(_user_id, "timezone", body) when is_map(body), do: Timezone.call(body)

  def invoke(_user_id, "paystack-fetch-banks", body) when is_map(body),
    do: Paystack.fetch_banks(body)

  def invoke(user_id, "paystack-resolve-bank-account", body) when is_map(body),
    do: Paystack.resolve_bank_account(user_id, body)

  def invoke(user_id, "paystack-create-transfer-recipient", body) when is_map(body),
    do: Paystack.create_transfer_recipient(user_id, body)

  def invoke(user_id, "paystack-initiate-transfer", body) when is_map(body),
    do: Paystack.initiate_transfer(user_id, body)

  def invoke(user_id, "connect-property-calendar", body) when is_map(body),
    do: ConnectPropertyCalendar.call(user_id, body)

  def invoke(user_id, "claim-job", body) when is_map(body),
    do: ClaimJob.call(user_id, body)

  def invoke(user_id, "send-app-notification", body) when is_map(body),
    do: SendAppNotification.call(user_id, body)

  def invoke(user_id, "sumsub-config/token", body) when is_map(body),
    do: SumsubToken.call(user_id, body)

  def invoke(user_id, "sync-sumsub-review", body) when is_map(body),
    do: SyncSumsubReview.call(user_id, body)

  def invoke(user_id, "create-job-and-notify", body) when is_map(body),
    do: CreateJobAndNotify.call(user_id, body)

  def invoke(user_id, "uber-transportation-release-gate", body) when is_map(body),
    do: UberTransportationReleaseGate.call(user_id, body)

  def invoke(user_id, "uber-trip-estimate", body) when is_map(body),
    do: UberTripEstimate.call(user_id, body)

  def invoke(user_id, "delete-property-media", body) when is_map(body),
    do: DeletePropertyMedia.call(user_id, body)

  def invoke(user_id, "cancel-subscription", body) when is_map(body),
    do: CancelSubscription.call(user_id, body)

  def invoke(user_id, "notify-booking-rescheduled", body) when is_map(body),
    do: NotifyBookingRescheduled.call(user_id, body)

  def invoke(user_id, "notify-payment-failure-ops", body) when is_map(body),
    do: NotifyPaymentFailureOps.call(user_id, body)

  def invoke(_user_id, "rank-cleaners-with-ai", body) when is_map(body),
    do: RankCleanersWithAi.call(nil, body)

  def invoke(user_id, "request-data-export", body) when is_map(body),
    do: RequestDataExport.call(user_id, body)

  def invoke(_user_id, _name, _body), do: {:error, :unknown_function}
end
