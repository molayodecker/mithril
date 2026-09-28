defmodule Mithril.Workers.DatabaseCron do
  @moduledoc false

  use Oban.Worker, queue: :cron, max_attempts: 1, unique: [period: 60, keys: [:name]]

  require Logger

  alias Mithril.Repo

  # SQL statements for jobs listed in `Mithril.Cron.Jobs` (imported from jzevawnetjwnliamyilb).
  @statements %{
    "auth_lookup_rate_limit_prune" =>
      "DELETE FROM public.auth_lookup_rate_limit WHERE window_start < now() - interval '1 hour'",
    "auto-close-stale-bookings" =>
      "SELECT public.auto_close_stale_bookings(interval '1 day', 100)",
    "broadcast-unassigned-paid-bookings" => "SELECT public.broadcast_unassigned_paid_bookings()",
    "cleanup-expired-welcome-promo-reservations" =>
      "SELECT public.cleanup_expired_welcome_promotion_reservations()",
    "escalate-unassigned-paid-bookings-past-grace" =>
      "SELECT public.escalate_unassigned_paid_bookings_past_grace()",
    "expire_stale_pending_bookings_job" => "SELECT public.expire_stale_pending_bookings()",
    "process-direct-assignment-holds" => "SELECT public.process_direct_assignment_holds()",
    "refresh_cleaner_health_snapshots" =>
      "SELECT public.refresh_cleaner_health_snapshots(current_date)",
    "release_cleaner_hold_15min" => "SELECT public.release_cleaner_after_15min_hold()"
  }

  def statement(name) when is_binary(name), do: Map.get(@statements, name)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"name" => name}}) when is_binary(name) do
    case statement(name) do
      sql when is_binary(sql) ->
        case Repo.query(sql) do
          {:ok, _result} ->
            Logger.info("database_cron name=#{name} ok")
            :ok

          {:error, error} ->
            Logger.warning("database_cron name=#{name} failed")
            {:error, error}
        end

      nil ->
        :discard
    end
  end

  def perform(_job), do: :discard
end
