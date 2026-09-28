defmodule Mithril.ObjectStorage.TestDouble do
  @moduledoc false

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> initial_state(opts) end, name: test_name())
  end

  @spec test_name() :: atom()
  def test_name, do: :object_storage_test_double

  @spec reset!() :: :ok
  def reset! do
    Agent.update(test_name(), fn _ -> initial_state([]) end)
  end

  @spec put_listing(String.t(), String.t(), [map()]) :: :ok
  def put_listing(bucket, prefix, entries) do
    Agent.update(test_name(), fn state ->
      listings = Map.put(state.listings, {bucket, prefix}, entries)
      %{state | listings: listings}
    end)
  end

  @spec put_recursive(String.t(), String.t(), [String.t()]) :: :ok
  def put_recursive(bucket, prefix, paths) do
    Agent.update(test_name(), fn state ->
      recursive = Map.put(state.recursive, {bucket, prefix}, paths)
      %{state | recursive: recursive}
    end)
  end

  @spec deleted_paths() :: [String.t()]
  def deleted_paths do
    Agent.get(test_name(), & &1.deleted)
  end

  @spec list_objects(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_objects(bucket, prefix) do
    entries = Agent.get(test_name(), &Map.get(&1.listings, {bucket, prefix}, []))
    {:ok, entries}
  end

  @spec list_objects_recursive(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_objects_recursive(bucket, prefix) do
    paths = Agent.get(test_name(), &Map.get(&1.recursive, {bucket, prefix}, []))
    {:ok, paths}
  end

  @spec remove_object(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_object(_bucket, path) do
    case Agent.get(test_name(), &Map.get(&1.fail_paths, path)) do
      true ->
        {:error, :failed}

      _ ->
        Agent.update(test_name(), fn state ->
          %{state | deleted: [path | state.deleted]}
        end)

        :ok
    end
  end

  @spec fail_delete(String.t()) :: :ok
  def fail_delete(path) do
    Agent.update(test_name(), fn state ->
      %{state | fail_paths: Map.put(state.fail_paths, path, true)}
    end)
  end

  defp initial_state(opts) do
    %{
      listings: Keyword.get(opts, :listings, %{}),
      recursive: Keyword.get(opts, :recursive, %{}),
      deleted: [],
      fail_paths: %{}
    }
  end
end
