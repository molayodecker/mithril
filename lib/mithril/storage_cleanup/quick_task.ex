defmodule Mithril.StorageCleanup.QuickTask do
  @moduledoc false

  alias Mithril.ObjectStorage

  @spec delete_paths([String.t()], String.t()) :: :ok | {:error, :storage_deletion_failed}
  def delete_paths(paths, bucket) when is_list(paths) and is_binary(bucket) do
    results = Enum.map(paths, &ObjectStorage.remove_object(bucket, &1))

    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:error, :storage_deletion_failed}
    else
      :ok
    end
  end

  @spec decode_claim(term()) :: %{paths: [String.t()], claim_id: term()}
  def decode_claim(json) when is_map(json) do
    paths =
      case Map.get(json, "paths") do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    %{paths: paths, claim_id: Map.get(json, "claim_id")}
  end

  def decode_claim(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode_claim(map)
      _ -> %{paths: [], claim_id: nil}
    end
  end

  def decode_claim(_), do: %{paths: [], claim_id: nil}

  @spec should_continue_batch?(non_neg_integer(), pos_integer()) :: boolean()
  def should_continue_batch?(path_count, limit)
      when is_integer(path_count) and is_integer(limit) do
    path_count >= limit
  end
end
