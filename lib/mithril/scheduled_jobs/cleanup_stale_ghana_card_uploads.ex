defmodule Mithril.ScheduledJobs.CleanupStaleGhanaCardUploads do
  @moduledoc false

  require Logger

  alias Mithril.ObjectStorage
  alias Mithril.Repo
  alias Mithril.StorageCleanup.GhanaCard

  @ghana_prefix "ghana-cards"
  @recruitment_prefix "recruitment"

  @spec run() :: :ok | {:error, term()}
  def run do
    bucket = Application.get_env(:mithril, :ghana_card_bucket, "cleaner-ghana-card-id")

    with {:ok, ghana_children} <- ObjectStorage.list_objects(bucket, @ghana_prefix),
         {:ok, recruitment_children} <- ObjectStorage.list_objects(bucket, @recruitment_prefix) do
      ghana_ids = GhanaCard.child_folder_ids(ghana_children)
      recruitment_ids = GhanaCard.child_folder_ids(recruitment_children)

      with {:ok, existing_users} <- load_existing_ids("users", ghana_ids),
           {:ok, existing_leads} <- load_existing_ids("cleaner_leads", recruitment_ids) do
        orphan_ghana = GhanaCard.orphan_folder_ids(ghana_ids, existing_users)
        orphan_leads = GhanaCard.orphan_folder_ids(recruitment_ids, existing_leads)

        removed =
          Enum.reduce(orphan_ghana, 0, fn folder_id, count ->
            count + remove_prefix(bucket, "#{@ghana_prefix}/#{folder_id}")
          end) +
            Enum.reduce(orphan_leads, 0, fn folder_id, count ->
              count + remove_prefix(bucket, "#{@recruitment_prefix}/#{folder_id}")
            end)

        Logger.info("cleanup_stale_ghana_card_uploads removed=#{removed}")
        :ok
      end
    else
      {:error, :not_configured} ->
        Logger.warning("cleanup_stale_ghana_card_uploads skipped storage_not_configured")
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_existing_ids(_table, ids) when ids == [], do: {:ok, MapSet.new()}

  defp load_existing_ids(table, ids) do
    ids
    |> Enum.chunk_every(150)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn chunk, {:ok, acc} ->
      case Repo.query("SELECT id::text FROM public.#{table} WHERE id = ANY($1::uuid[])", [chunk]) do
        {:ok, %{rows: rows}} ->
          {:cont, {:ok, Enum.reduce(rows, acc, fn [id], set -> MapSet.put(set, id) end)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp remove_prefix(bucket, prefix) do
    case ObjectStorage.list_objects_recursive(bucket, prefix) do
      {:ok, paths} ->
        Enum.each(paths, &ObjectStorage.remove_object(bucket, &1))
        length(paths)

      _ ->
        0
    end
  end
end
