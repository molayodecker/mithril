defmodule Mithril.SupabaseStorage do
  @moduledoc false

  @spec list_objects(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_objects(bucket, prefix) when is_binary(bucket) and is_binary(prefix) do
    with {:ok, base_url, service_key} <- config() do
      url = "#{base_url}/storage/v1/object/list/#{URI.encode(bucket)}"
      body = %{prefix: prefix, limit: 1000, offset: 0}

      case Req.post(url, json: body, headers: auth_headers(service_key)) do
        {:ok, %{status: status, body: entries}} when status in 200..299 and is_list(entries) ->
          {:ok, entries}

        _ ->
          {:error, :failed}
      end
    end
  end

  @spec list_objects_recursive(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_objects_recursive(bucket, prefix) do
    case walk(bucket, prefix, []) do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  @spec remove_object(String.t(), String.t()) ::
          :ok | {:error, :not_configured | :failed | :missing}
  def remove_object(bucket, object_path) when is_binary(bucket) and is_binary(object_path) do
    path = String.trim(object_path)

    with {:ok, base_url, service_key} <- config(),
         true <- path != "" do
      url = "#{base_url}/storage/v1/object/#{URI.encode(bucket)}/#{encode_object_path(path)}"

      case Req.delete(url, headers: auth_headers(service_key)) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 404}} ->
          :ok

        _ ->
          {:error, :failed}
      end
    else
      false -> {:error, :missing}
      {:error, :not_configured} -> {:error, :not_configured}
    end
  end

  defp config do
    base_url = Application.get_env(:mithril, :supabase_url)
    service_key = Application.get_env(:mithril, :supabase_service_role_key)

    if is_binary(base_url) and base_url != "" and is_binary(service_key) and service_key != "" do
      {:ok, String.trim_trailing(base_url, "/"), service_key}
    else
      {:error, :not_configured}
    end
  end

  defp auth_headers(service_key) do
    [
      {"authorization", "Bearer #{service_key}"},
      {"apikey", service_key}
    ]
  end

  defp walk(bucket, prefix, paths) do
    case list_objects(bucket, prefix) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, paths}, fn entry, {:ok, acc} ->
          name = Map.get(entry, "name") |> to_string() |> String.trim()

          cond do
            name == "" ->
              {:cont, {:ok, acc}}

            storage_folder?(entry) ->
              child_prefix = if prefix == "", do: name, else: "#{prefix}/#{name}"

              case walk(bucket, child_prefix, acc) do
                {:ok, nested} -> {:cont, {:ok, nested}}
                error -> {:halt, error}
              end

            true ->
              object_path = if prefix == "", do: name, else: "#{prefix}/#{name}"
              {:cont, {:ok, [object_path | acc]}}
          end
        end)

      error ->
        error
    end
  end

  defp storage_folder?(entry) do
    Map.get(entry, "id") in [nil, ""]
  end

  defp encode_object_path(path) do
    path
    |> String.split("/")
    |> Enum.map(&URI.encode/1)
    |> Enum.join("/")
  end
end
