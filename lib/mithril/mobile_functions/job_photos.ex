defmodule Mithril.MobileFunctions.JobPhotos do
  @moduledoc """
  Authenticated job-photo operations for private Cloudflare R2 media.
  """

  alias Mithril.DbUuid
  alias Mithril.Repo
  alias Mithril.R2Storage

  @booking_id ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @photo_path ~r/^[0-9a-f-]{36}\/\d{16,}-(before|during|after|issue)\.(jpg|jpeg|png|webp)$/i
  @composite_path ~r/^[0-9a-f-]{36}\/comparisons\/[0-9a-f-]{36}\.png$/i
  @max_bytes 5 * 1024 * 1024

  def upload(user_id, body) do
    with {:ok, booking_id, path} <- validate(body),
         :ok <- authorize(user_id, booking_id, :write),
         {:ok, bytes} <- decode(body["data_base64"]),
         :ok <- validate_mime(path, body["content_type"]),
         :ok <- R2Storage.put("job-photos/" <> path, bytes, body["content_type"]),
         {:ok, url} <- R2Storage.signed_url("job-photos/" <> path) do
      {:ok, %{path: path, url: url}}
    else
      {:error, reason} -> fail(reason)
    end
  end

  def url(user_id, body) do
    with {:ok, booking_id, path} <- validate(body),
         :ok <- authorize(user_id, booking_id, :read),
         :ok <- registered(booking_id, path),
         {:ok, url} <- R2Storage.signed_url("job-photos/" <> path, expiry(body)) do
      {:ok, %{path: path, url: url}}
    else
      {:error, reason} -> fail(reason)
    end
  end

  def delete(user_id, body) do
    with {:ok, booking_id, path} <- validate(body),
         :ok <- authorize(user_id, booking_id, :write),
         :ok <- unregistered(booking_id, path),
         :ok <- R2Storage.delete("job-photos/" <> path) do
      {:ok, %{deleted: true}}
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp validate(%{"booking_id" => booking_id, "storage_path" => path})
       when is_binary(booking_id) and is_binary(path) do
    if Regex.match?(@booking_id, booking_id) and
         String.starts_with?(path, booking_id <> "/") and
         (Regex.match?(@photo_path, path) or valid_composite_path?(path)) do
      {:ok, booking_id, path}
    else
      {:error, :bad_request}
    end
  end

  defp validate(_), do: {:error, :bad_request}

  defp valid_composite_path?(path) do
    Regex.match?(@composite_path, path) and
      Regex.match?(@booking_id, path |> String.split("/") |> List.last() |> Path.rootname())
  end

  defp authorize(user_id, booking_id, mode) when is_binary(user_id) do
    sql =
      if mode == :write do
        """
        SELECT 1 FROM public.bookings
        WHERE id = $1::uuid
          AND cleaner_id = $2::uuid
          AND status::text NOT IN ('cancelled', 'completed')
        LIMIT 1
        """
      else
        """
        SELECT 1 FROM public.bookings
        WHERE id = $1::uuid
          AND (cleaner_id = $2::uuid OR customer_id = $2::uuid)
        LIMIT 1
        """
      end

    case Repo.query(sql, [DbUuid.dump!(booking_id), DbUuid.dump!(user_id)]) do
      {:ok, %{rows: [[1]]}} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_, _, _), do: {:error, :forbidden}

  defp registered(booking_id, path) do
    query =
      if Regex.match?(@composite_path, path) do
        comparison_id = path |> String.split("/") |> List.last() |> Path.rootname()

        Repo.query(
          """
          SELECT 1 FROM public.job_photo_comparisons
          WHERE booking_id = $1::uuid AND id = $2::uuid
          LIMIT 1
          """,
          [DbUuid.dump!(booking_id), DbUuid.dump!(comparison_id)]
        )
      else
        Repo.query(
          """
          SELECT 1 FROM public.booking_job_photos
          WHERE booking_id = $1::uuid AND storage_path = $2
          LIMIT 1
          """,
          [DbUuid.dump!(booking_id), path]
        )
      end

    case query do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :database_unavailable}
      _ -> {:error, :database_unavailable}
    end
  end

  defp unregistered(booking_id, path) do
    case registered(booking_id, path) do
      {:error, :not_found} -> :ok
      :ok -> {:error, :still_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(value) when is_binary(value) and byte_size(value) <= 7_100_000 do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      _ -> {:error, :invalid_photo}
    end
  end

  defp decode(_), do: {:error, :invalid_photo}

  defp validate_mime(path, mime) do
    valid =
      case String.downcase(Path.extname(path)) do
        ".jpg" -> "image/jpeg"
        ".jpeg" -> "image/jpeg"
        ".png" -> "image/png"
        ".webp" -> "image/webp"
        _ -> nil
      end

    if valid == mime, do: :ok, else: {:error, :invalid_photo}
  end

  defp expiry(%{"expires_in" => seconds}) when is_integer(seconds),
    do: min(max(seconds, 1), 604_800)

  defp expiry(_), do: 3600

  defp fail(:forbidden), do: {:error, {:status, 403, %{error: "forbidden"}}}
  defp fail(:not_found), do: {:error, {:status, 404, %{error: "not_found"}}}
  defp fail(:database_unavailable),
    do: {:error, {:status, 503, %{error: "database_unavailable"}}}

  defp fail(:storage_unavailable), do: {:error, {:status, 502, %{error: "storage_unavailable"}}}

  defp fail(:storage_not_configured),
    do: {:error, {:status, 503, %{error: "storage_not_configured"}}}

  defp fail(reason), do: {:error, {:status, 400, %{error: to_string(reason)}}}
end
