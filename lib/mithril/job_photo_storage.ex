defmodule Mithril.JobPhotoStorage do
  @moduledoc false

  @prefix "job-photos/"

  @spec put(String.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def put(relative_path, body, content_type)
      when is_binary(relative_path) and is_binary(body) and is_binary(content_type) do
    backend().put_job_photo(object_key(relative_path), body, content_type)
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(relative_path) when is_binary(relative_path) do
    backend().delete_job_photo(object_key(relative_path))
  end

  @spec object_key(String.t()) :: String.t()
  def object_key(relative_path) do
    @prefix <> relative_path
  end

  defp backend do
    Application.get_env(:mithril, :job_photo_storage_backend, Mithril.R2Storage)
  end
end
