defmodule Mithril.WhatsApp.Recruitment.Storage do
  @moduledoc false

  require Logger

  @max_bytes 5_000_000

  def upload(path, body, content_type) do
    with {:ok, env} <- storage_env() do
      url = "#{env.base}/storage/v1/object/#{env.bucket}/#{path}"

      case Req.post(url,
             headers: [
               {"authorization", "Bearer #{env.service_key}"},
               {"apikey", env.service_key},
               {"content-type", content_type},
               {"x-upsert", "true"}
             ],
             body: body
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          Logger.error("whatsapp recruitment storage upload failed status=#{status}")
          {:error, :upload_failed}

        {:error, error} ->
          Logger.error("whatsapp recruitment storage upload failed #{inspect(error)}")
          {:error, :upload_failed}
      end
    end
  end

  def download_ok?(path) when is_binary(path) and path != "" do
    with {:ok, env} <- storage_env() do
      url = "#{env.base}/storage/v1/object/#{env.bucket}/#{path}"

      case Req.get(url,
             headers: [
               {"authorization", "Bearer #{env.service_key}"},
               {"apikey", env.service_key}
             ]
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
          byte_size(body) <= @max_bytes and
            sniff(body) in ["image/jpeg", "image/png", "image/webp"]

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  def download_ok?(_), do: false

  def list_latest(folder, prefix) do
    with {:ok, env} <- storage_env() do
      url = "#{env.base}/storage/v1/object/list/#{env.bucket}"

      case Req.post(url,
             json: %{prefix: folder, limit: 200, sortBy: %{column: "updated_at", order: "desc"}},
             headers: [
               {"authorization", "Bearer #{env.service_key}"},
               {"apikey", env.service_key}
             ]
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
          body
          |> Enum.map(&Map.get(&1, "name"))
          |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, prefix)))
          |> Enum.map(&"#{folder}/#{&1}")

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: "image/png"

  def sniff(<<0x52, 0x49, 0x46, 0x46, _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(_), do: nil

  def max_bytes, do: @max_bytes

  defp storage_env do
    url = Application.get_env(:mithril, :supabase_url)
    key = Application.get_env(:mithril, :supabase_service_role_key)

    bucket =
      Application.get_env(:mithril, :ghana_card_recruitment_bucket, "cleaner-ghana-card-id")

    if is_binary(url) and url != "" and is_binary(key) and key != "" do
      {:ok, %{base: String.trim_trailing(url, "/"), service_key: key, bucket: bucket}}
    else
      {:error, :storage_not_configured}
    end
  end
end
