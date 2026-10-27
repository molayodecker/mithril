defmodule Mithril.R2Storage do
  @moduledoc false

  @bucket "instaclean-media"
  @api_base "https://api.cloudflare.com/client/v4"

  @spec put_job_photo(String.t(), binary(), String.t()) ::
          {:ok, String.t()} | {:error, :not_configured | :upload_failed}
  def put_job_photo(object_key, body, content_type)
      when is_binary(object_key) and is_binary(body) and is_binary(content_type) do
    with {:ok, env} <- config() do
      case Req.put(object_url(env, object_key),
             body: body,
             headers: auth_headers(env.api_token, content_type)
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, object_key}

        _ ->
          {:error, :upload_failed}
      end
    end
  end

  @spec delete_job_photo(String.t()) :: :ok | {:error, :not_configured | :delete_failed}
  def delete_job_photo(object_key) when is_binary(object_key) do
    with {:ok, env} <- config() do
      case Req.delete(object_url(env, object_key), headers: auth_headers(env.api_token, nil)) do
        {:ok, %{status: status}} when status in 200..299 or status == 404 ->
          :ok

        _ ->
          {:error, :delete_failed}
      end
    end
  end

  defp config do
    account_id = System.get_env("CLOUDFLARE_ACCOUNT_ID")
    api_token = System.get_env("CLOUDFLARE_API_TOKEN")

    if is_binary(account_id) and account_id != "" and is_binary(api_token) and api_token != "" do
      {:ok, %{account_id: account_id, api_token: api_token}}
    else
      {:error, :not_configured}
    end
  end

  defp object_url(env, object_key) do
    "#{@api_base}/accounts/#{env.account_id}/r2/buckets/#{@bucket}/objects/#{encode_key(object_key)}"
  end

  defp auth_headers(api_token, content_type) do
    headers = [{"authorization", "Bearer #{api_token}"}]

    if is_binary(content_type) and content_type != "" do
      headers ++ [{"content-type", content_type}]
    else
      headers
    end
  end

  # Slashes in the object key must stay literal. Encoding them as %2F stores a different key.
  defp encode_key(object_key) do
    object_key
    |> String.split("/")
    |> Enum.map(&URI.encode/1)
    |> Enum.join("/")
  end
end
