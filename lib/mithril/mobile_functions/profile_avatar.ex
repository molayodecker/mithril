defmodule Mithril.MobileFunctions.ProfileAvatar do
  @moduledoc """
  Authenticated profile photo uploads for private Cloudflare R2 media.
  """

  alias Mithril.DbUuid
  alias Mithril.Repo
  alias Mithril.R2Storage

  @max_bytes 5 * 1024 * 1024
  @signed_ttl 604_800
  @shared_signed_ttl 3_600
  @avatar_path ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\/avatar-\d+\.(jpg|jpeg|png|webp|gif)$/i

  def upload(user_id, body) when is_binary(user_id) and is_map(body) do
    with :ok <- valid_user(user_id),
         {:ok, mime, extension} <- mime(body["content_type"]),
         {:ok, bytes} <- decode(body["data_base64"]),
         path = object_path(user_id, extension),
         :ok <- R2Storage.put("avatars/" <> path, bytes, mime),
         {:ok, url} <- R2Storage.signed_url("avatars/" <> path, @signed_ttl) do
      {:ok, %{path: path, url: url}}
    else
      {:error, reason} -> fail(reason)
    end
  end

  def upload(_, _), do: {:error, {:status, 400, %{error: "bad_request"}}}

  def url(user_id, body) when is_binary(user_id) and is_map(body) do
    with :ok <- valid_user(user_id),
         {:ok, path} <- validate_path(body["storage_path"]),
         :ok <- authorize_view(user_id, path),
         {:ok, url} <- R2Storage.signed_url("avatars/" <> path, view_expiry(user_id, path, body)) do
      {:ok, %{path: path, url: url}}
    else
      {:error, reason} -> fail(reason)
    end
  end

  def url(_, _), do: {:error, {:status, 400, %{error: "bad_request"}}}

  def delete(user_id, body) when is_binary(user_id) and is_map(body) do
    with :ok <- valid_user(user_id),
         {:ok, path} <- validate_path(body["storage_path"]),
         :ok <- owned_by(user_id, path),
         :ok <- R2Storage.delete("avatars/" <> path) do
      {:ok, %{deleted: true}}
    else
      {:error, reason} -> fail(reason)
    end
  end

  def delete(_, _), do: {:error, {:status, 400, %{error: "bad_request"}}}

  defp valid_user(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, _} -> :ok
      :error -> {:error, :forbidden}
    end
  end

  defp mime(value) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()

    case normalized do
      "image/jpeg" -> {:ok, "image/jpeg", "jpg"}
      "image/png" -> {:ok, "image/png", "png"}
      "image/webp" -> {:ok, "image/webp", "webp"}
      "image/gif" -> {:ok, "image/gif", "gif"}
      _ -> {:error, :invalid_photo}
    end
  end

  defp mime(_), do: {:error, :invalid_photo}

  defp decode(value) when is_binary(value) and byte_size(value) <= 7_100_000 do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      _ -> {:error, :invalid_photo}
    end
  end

  defp decode(_), do: {:error, :invalid_photo}

  defp object_path(user_id, extension) do
    "#{user_id}/avatar-#{System.system_time(:millisecond)}.#{extension}"
  end

  # A private R2 object path is not an access token. Only sign the avatar
  # currently referenced by a profile the caller is entitled to view.
  defp authorize_view(user_id, path) do
    [owner_id | _] = String.split(path, "/", parts: 2)

    if DbUuid.equal?(user_id, owner_id) do
      :ok
    else
      can_view_registered_avatar?(user_id, owner_id, path)
    end
  end

  defp can_view_registered_avatar?(viewer_id, owner_id, path) do
    sql = """
    SELECT 1
    FROM public.profiles p
    WHERE p.id = $1::uuid
      AND (
        p.avatar_url = $2
        OR p.avatar_url LIKE ('%/avatars/' || $2 || '?%')
        OR p.avatar_url LIKE ('%/avatars/' || $2)
      )
      AND (
        EXISTS (
          SELECT 1 FROM public.cleaner_data cd
          WHERE cd.user_id = p.id AND cd.verified IS TRUE
        )
        OR EXISTS (
          SELECT 1 FROM public.bookings b
          WHERE (b.customer_id = $3::uuid AND b.cleaner_id = p.id)
             OR (b.cleaner_id = $3::uuid AND b.customer_id = p.id)
        )
        OR EXISTS (
          SELECT 1 FROM public.conversations c
          WHERE (c.customer_id = $3::uuid AND c.cleaner_id = p.id)
             OR (c.cleaner_id = $3::uuid AND c.customer_id = p.id)
        )
      )
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(owner_id), path, DbUuid.dump!(viewer_id)]) do
      {:ok, %{rows: [[1]]}} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp owned_by(user_id, path) do
    prefix = String.downcase(user_id) <> "/"

    if String.starts_with?(String.downcase(path), prefix) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp validate_path(path) when is_binary(path) do
    if Regex.match?(@avatar_path, path) and not String.contains?(path, "..") do
      {:ok, path}
    else
      {:error, :bad_request}
    end
  end

  defp validate_path(_), do: {:error, :bad_request}

  defp view_expiry(user_id, path, body) do
    [owner_id | _] = String.split(path, "/", parts: 2)
    requested = expiry(body)

    if DbUuid.equal?(user_id, owner_id) do
      requested
    else
      min(requested, @shared_signed_ttl)
    end
  end

  defp expiry(%{"expires_in" => seconds}) when is_integer(seconds),
    do: min(max(seconds, 1), @signed_ttl)

  defp expiry(_), do: @signed_ttl

  defp fail(:forbidden), do: {:error, {:status, 403, %{error: "forbidden"}}}

  defp fail(:storage_unavailable), do: {:error, {:status, 502, %{error: "storage_unavailable"}}}

  defp fail(:storage_not_configured),
    do: {:error, {:status, 503, %{error: "storage_not_configured"}}}

  defp fail(reason), do: {:error, {:status, 400, %{error: to_string(reason)}}}
end
