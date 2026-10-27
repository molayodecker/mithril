defmodule Mithril.MobileFunctions.UploadJobPhoto do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.JobPhotoStorage
  alias Mithril.Repo

  @max_bytes 5_000_000
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @photo_types ~w(before during after issue)
  @content_types ~w(image/jpeg image/png image/webp image/gif)

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    with {:ok, photo} <- normalize(body),
         :ok <- ensure_assigned(user_id, photo.booking_id),
         {:ok, object_key} <-
           JobPhotoStorage.put(photo.storage_path, photo.bytes, photo.content_type) do
      {:ok, %{path: photo.storage_path, key: object_key}}
    else
      {:error, :not_configured} ->
        {:error, {:status, 503, %{error: "Photo storage is not configured"}}}

      {:error, :upload_failed} ->
        {:error, {:status, 502, %{error: "Failed to upload photo."}}}

      other ->
        other
    end
  end

  @spec delete(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def delete(user_id, body) when is_binary(user_id) and is_map(body) do
    with {:ok, photo} <- normalize_delete(body),
         :ok <- ensure_assigned(user_id, photo.booking_id),
         :ok <- JobPhotoStorage.delete(photo.storage_path) do
      {:ok, %{deleted: true, path: photo.storage_path}}
    else
      {:error, :not_configured} ->
        {:error, {:status, 503, %{error: "Photo storage is not configured"}}}

      {:error, :delete_failed} ->
        {:error, {:status, 502, %{error: "Failed to delete photo."}}}

      other ->
        other
    end
  end

  defp normalize(body) do
    booking_id = trimmed(body, "booking_id")
    photo_type = body |> trimmed("photo_type") |> String.downcase()
    storage_path = trimmed(body, "storage_path")
    content_type = body |> trimmed("content_type") |> String.downcase()
    encoded = body |> Map.get("data_base64", "") |> to_string()

    with :ok <- require_uuid(booking_id),
         :ok <- require_photo_type(photo_type),
         :ok <- require_content_type(content_type),
         :ok <- require_storage_path(booking_id, photo_type, content_type, storage_path),
         {:ok, bytes} <- decode_image(encoded) do
      {:ok,
       %{
         booking_id: booking_id,
         storage_path: storage_path,
         content_type: content_type,
         bytes: bytes
       }}
    end
  end

  defp normalize_delete(body) do
    booking_id = trimmed(body, "booking_id")
    storage_path = trimmed(body, "storage_path")

    with :ok <- require_uuid(booking_id),
         :ok <- require_owned_path(booking_id, storage_path) do
      {:ok, %{booking_id: booking_id, storage_path: storage_path}}
    end
  end

  defp ensure_assigned(user_id, booking_id) do
    case Repo.query(
           "SELECT cleaner_id FROM public.bookings WHERE id = $1::uuid LIMIT 1",
           [DbUuid.dump!(booking_id)]
         ) do
      {:ok, %{rows: [[cleaner_id]]}} ->
        if DbUuid.equal?(cleaner_id, user_id) do
          :ok
        else
          {:error, {:status, 403, %{error: "Only the assigned cleaner can manage job photos."}}}
        end

      {:ok, %{rows: []}} ->
        {:error, {:status, 404, %{error: "Booking not found"}}}

      _ ->
        {:error, {:status, 500, %{error: "Could not verify job access."}}}
    end
  end

  defp decode_image(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= @max_bytes ->
        {:ok, bytes}

      {:ok, _} ->
        {:error, {:status, 400, %{error: "Image must be less than 5MB."}}}

      :error ->
        {:error, {:status, 400, %{error: "Invalid image data"}}}
    end
  end

  defp require_uuid(booking_id) do
    if Regex.match?(@uuid_regex, booking_id) do
      :ok
    else
      {:error, {:status, 400, %{error: "Invalid booking_id"}}}
    end
  end

  defp require_photo_type(photo_type) do
    if photo_type in @photo_types do
      :ok
    else
      {:error, {:status, 400, %{error: "Invalid photo type"}}}
    end
  end

  defp require_content_type(content_type) do
    if content_type in @content_types do
      :ok
    else
      {:error, {:status, 400, %{error: "Invalid image type"}}}
    end
  end

  defp require_storage_path(booking_id, photo_type, content_type, storage_path) do
    extension = extension_for(content_type)

    if Regex.match?(
         ~r/^#{Regex.escape(booking_id)}\/[0-9]{13,16}-#{photo_type}\.#{extension}$/,
         storage_path
       ) do
      :ok
    else
      {:error, {:status, 400, %{error: "Invalid storage path"}}}
    end
  end

  defp require_owned_path(booking_id, storage_path) do
    if Regex.match?(
         ~r/^#{Regex.escape(booking_id)}\/[0-9]{13,16}-(before|during|after|issue)\.(jpg|png|webp|gif)$/,
         storage_path
       ) do
      :ok
    else
      {:error, {:status, 400, %{error: "Invalid storage path"}}}
    end
  end

  defp extension_for("image/png"), do: "png"
  defp extension_for("image/webp"), do: "webp"
  defp extension_for("image/gif"), do: "gif"
  defp extension_for("image/jpeg"), do: "jpg"

  defp trimmed(body, key) do
    body |> Map.get(key, "") |> to_string() |> String.trim()
  end
end
