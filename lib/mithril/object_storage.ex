defmodule Mithril.ObjectStorage do
  @moduledoc """
  Object storage facade. Production uses `Mithril.SupabaseStorage` (S3-compatible API).
  Tests may set `:object_storage_backend` to a stub module.
  """

  @spec backend() :: module()
  def backend do
    Application.get_env(:mithril, :object_storage_backend, Mithril.SupabaseStorage)
  end

  @spec list_objects(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_objects(bucket, prefix), do: backend().list_objects(bucket, prefix)

  @spec list_objects_recursive(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_objects_recursive(bucket, prefix),
    do: backend().list_objects_recursive(bucket, prefix)

  @spec remove_object(String.t(), String.t()) ::
          :ok | {:error, :not_configured | :failed | :missing}
  def remove_object(bucket, path), do: backend().remove_object(bucket, path)
end
