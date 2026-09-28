defmodule Mithril.ScheduledJobs.CleanerApplicationOpsReminders do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.SupportOps

  @pending_hours 24
  @draft_hours 48
  @batch_limit 40

  @spec run() :: :ok | {:error, term()}
  def run do
    now = DateTime.utc_now()
    pending_cutoff = DateTime.add(now, -@pending_hours * 3600, :second) |> DateTime.to_iso8601()
    draft_cutoff = DateTime.add(now, -@draft_hours * 3600, :second) |> DateTime.to_iso8601()
    admin_url = admin_cleaners_url()

    with :ok <- remind_pending(pending_cutoff, admin_url),
         :ok <- remind_stale_drafts(draft_cutoff, admin_url) do
      :ok
    end
  end

  defp remind_pending(cutoff, admin_url) do
    case Repo.query(
           """
           SELECT id, name, email, phone, status, updated_at
           FROM public.cleaner_applications
           WHERE status = 'pending'
             AND ops_pending_review_reminder_sent_at IS NULL
             AND updated_at <= $1::timestamptz
           ORDER BY updated_at ASC
           LIMIT $2
           """,
           [cutoff, @batch_limit]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn [id, name, email, phone, status, updated_at] ->
          body =
            [
              "This application is still pending review after at least 24 hours.",
              "",
              "Application ID: #{id}",
              "Name: #{name || ""}",
              "Email: #{email || "(none)"}",
              "Phone: #{phone || ""}",
              "Status: #{status || "pending"}",
              "Last updated (UTC): #{updated_at}",
              "",
              "Admin: #{admin_url}"
            ]
            |> Enum.join("\n")

          if SupportOps.delivered?(
               SupportOps.notify(%{subject: subject_pending(), plain_body: body})
             ) do
            stamp_pending(id)
          end
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp remind_stale_drafts(cutoff, admin_url) do
    case Repo.query(
           """
           SELECT id, user_id, email, current_step, updated_at
           FROM public.cleaner_application_drafts
           WHERE ops_stale_draft_reminder_sent_at IS NULL
             AND updated_at <= $1::timestamptz
           ORDER BY updated_at ASC
           LIMIT $2
           """,
           [cutoff, @batch_limit]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn [id, user_id, email, current_step, updated_at] ->
          body =
            [
              "A join-as-cleaner web draft has had no saves for at least 48 hours.",
              "",
              "Draft ID: #{id}",
              "User ID: #{user_id || ""}",
              "Email: #{email || "(none)"}",
              "Current step: #{current_step || ""}",
              "Last updated (UTC): #{updated_at}",
              "",
              "Admin: #{admin_url}"
            ]
            |> Enum.join("\n")

          if SupportOps.delivered?(
               SupportOps.notify(%{subject: subject_draft(), plain_body: body})
             ) do
            stamp_draft(id)
          end
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp stamp_pending(id) do
    Repo.query!(
      """
      UPDATE public.cleaner_applications
      SET ops_pending_review_reminder_sent_at = now()
      WHERE id = $1::uuid AND ops_pending_review_reminder_sent_at IS NULL
      """,
      [id]
    )
  end

  defp stamp_draft(id) do
    Repo.query!(
      """
      UPDATE public.cleaner_application_drafts
      SET ops_stale_draft_reminder_sent_at = now()
      WHERE id = $1::uuid AND ops_stale_draft_reminder_sent_at IS NULL
      """,
      [id]
    )
  end

  defp subject_pending, do: "[Instaclean] Reminder: cleaner application still pending"
  defp subject_draft, do: "[Instaclean] Reminder: cleaner draft inactive 48h+"

  defp admin_cleaners_url do
    Application.get_env(:mithril, :app_url, "https://tryinstaclean.com")
    |> to_string()
    |> String.trim_trailing("/")
    |> Kernel.<>("/admin/cleaners")
  end
end
