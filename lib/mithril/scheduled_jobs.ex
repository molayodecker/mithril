defmodule Mithril.ScheduledJobs do
  @moduledoc """
  Native scheduled work imported from Supabase `pg_cron` + Edge Functions.

  All Tier 2 jobs run entirely in Mithril (no Supabase Edge HTTP fallback).
  """

  alias Mithril.ScheduledJobs.{
    AdminBroadcastWorker,
    BookingCustomerReminders,
    BookingOpsReminders,
    BookingReviewRequests,
    ChargeManagedSubscriptionRenewals,
    CleanerWalletCreditNotifications,
    CleanerApplicationOpsReminders,
    CleanupExpiredCleaningScanMedia,
    CleanupOrphanedQuickTaskUploads,
    CleanupStaleGhanaCardUploads,
    MessageDeliveryFallback,
    PaymentFailureOpsRetry,
    SyncPropertyCalendarFeeds
  }

  @native_modules %{
    "admin-broadcast-worker" => AdminBroadcastWorker,
    "booking-customer-reminders" => BookingCustomerReminders,
    "booking-ops-reminders" => BookingOpsReminders,
    "booking-review-requests" => BookingReviewRequests,
    "charge-managed-subscription-renewals" => ChargeManagedSubscriptionRenewals,
    "cleaner-wallet-credit-notifications" => CleanerWalletCreditNotifications,
    "cleaner-application-ops-reminders" => CleanerApplicationOpsReminders,
    "cleanup-expired-cleaning-scan-media" => CleanupExpiredCleaningScanMedia,
    "cleanup-orphaned-quick-task-uploads" => CleanupOrphanedQuickTaskUploads,
    "cleanup-stale-ghana-card-uploads-daily" => CleanupStaleGhanaCardUploads,
    "message-delivery-fallback" => MessageDeliveryFallback,
    "retry-payment-failure-ops-alerts" => PaymentFailureOpsRetry,
    "sync-property-calendar-feeds" => SyncPropertyCalendarFeeds
  }

  @spec native_job_names() :: [String.t()]
  def native_job_names, do: Map.keys(@native_modules)

  @spec run(String.t()) :: :ok | {:error, term()}
  def run(name) when is_binary(name) do
    case Map.get(@native_modules, name) do
      module when not is_nil(module) ->
        case module.run() do
          :ok -> :ok
          {:error, _} = error -> error
        end

      nil ->
        {:error, {:unknown_scheduled_job, name}}
    end
  end
end
