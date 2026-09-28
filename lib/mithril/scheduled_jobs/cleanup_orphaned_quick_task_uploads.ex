defmodule Mithril.ScheduledJobs.CleanupOrphanedQuickTaskUploads do
  @moduledoc false

  require Logger

  alias Mithril.Repo
  alias Mithril.StorageCleanup.QuickTask

  @bucket "quick-task-photos"
  @default_older_than "24 hours"
  @default_limit 200
  @default_max_pages 10

  @spec run() :: :ok | {:error, term()}
  def run do
    pages = 0
    max_pages = @default_max_pages
    limit = @default_limit
    older_than = @default_older_than

    do_pages(pages, max_pages, limit, older_than, 0)
  end

  defp do_pages(pages, max_pages, _limit, _older_than, path_total) when pages >= max_pages,
    do: ok(path_total)

  defp do_pages(pages, max_pages, limit, older_than, path_total) do
    pages = pages + 1

    case Repo.query(
           "SELECT public.claim_orphaned_quick_task_uploads_for_cleanup($1::interval, $2)",
           [older_than, limit]
         ) do
      {:ok, %{rows: [[claim_json]]}} ->
        claim = QuickTask.decode_claim(claim_json)
        paths = claim.paths
        claim_id = claim.claim_id

        if paths == [] do
          ok(path_total)
        else
          case QuickTask.delete_paths(paths, @bucket) do
            :ok ->
              finalize(paths, claim_id)
              next_total = path_total + length(paths)

              if QuickTask.should_continue_batch?(length(paths), limit) do
                do_pages(pages, max_pages, limit, older_than, next_total)
              else
                ok(next_total)
              end

            {:error, error} ->
              release_claim(claim_id)
              {:error, error}
          end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp finalize(paths, claim_id) do
    Repo.query("SELECT public.finalize_orphaned_quick_task_uploads($1::text[], $2::uuid)", [
      paths,
      claim_id
    ])
  end

  defp release_claim(claim_id) do
    Repo.query("SELECT public.release_orphaned_quick_task_upload_claim($1::uuid)", [claim_id])
  end

  defp ok(path_total) do
    Logger.info("cleanup_orphaned_quick_task_uploads path_count=#{path_total}")
    :ok
  end
end
