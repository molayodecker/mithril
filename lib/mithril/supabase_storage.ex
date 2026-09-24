defmodule Mithril.SupabaseStorage do
  @moduledoc false

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

  defp encode_object_path(path) do
    path
    |> String.split("/")
    |> Enum.map(&URI.encode/1)
    |> Enum.join("/")
  end
end
