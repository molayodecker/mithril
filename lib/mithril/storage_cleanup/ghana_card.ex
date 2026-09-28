defmodule Mithril.StorageCleanup.GhanaCard do
  @moduledoc false

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @spec child_folder_ids([map()]) :: [String.t()]
  def child_folder_ids(children) when is_list(children) do
    children
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@uuid_regex, &1))
  end

  @spec orphan_folder_ids([String.t()], MapSet.t()) :: [String.t()]
  def orphan_folder_ids(folder_ids, existing_ids) when is_list(folder_ids) do
    Enum.reject(folder_ids, &MapSet.member?(existing_ids, &1))
  end

  @spec removal_prefixes([String.t()], [String.t()], String.t(), String.t()) :: [String.t()]
  def removal_prefixes(orphan_ghana, orphan_leads, ghana_prefix, recruitment_prefix) do
    Enum.map(orphan_ghana, &"#{ghana_prefix}/#{&1}") ++
      Enum.map(orphan_leads, &"#{recruitment_prefix}/#{&1}")
  end
end
