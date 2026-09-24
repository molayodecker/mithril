defmodule Mithril.MobileFunctions.DeletePropertyMedia do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Repo
  alias Mithril.SupabaseStorage

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @bucket "property-media"

  def call(user_id, body) when is_map(body) do
    media_id = body |> Map.get("media_id", "") |> to_string() |> String.trim()

    cond do
      not Regex.match?(@uuid_regex, media_id) ->
        {:error, {:status, 400, %{error: "media_id must be a UUID"}}}

      true ->
        with {:ok, media_row} <- load_media(media_id),
             :ok <- ensure_owner(media_row, user_id),
             :ok <- remove_storage(Map.get(media_row, "storage_path")),
             :ok <- delete_metadata(media_row, user_id) do
          {:ok, %{success: true, media_id: media_id}}
        end
    end
  end

  defp load_media(media_id) do
    sql = """
    SELECT id, property_id, owner_id, storage_path
    FROM public.property_media
    WHERE id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(media_id)]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, map_row(columns, row)}
      {:ok, %{rows: []}} -> {:error, {:status, 404, %{error: "Media not found"}}}
      {:error, _} -> {:error, {:status, 500, %{error: "Could not load media"}}}
    end
  end

  defp ensure_owner(media_row, user_id) do
    property_id = Map.get(media_row, "property_id")

    with {:ok, property_row} <- load_property(property_id) do
      if DbUuid.equal?(Map.get(property_row, "customer_id"), user_id) and
           DbUuid.equal?(Map.get(media_row, "owner_id"), user_id) do
        :ok
      else
        {:error, {:status, 403, %{error: "Forbidden"}}}
      end
    end
  end

  defp load_property(property_id) do
    sql = "SELECT id, customer_id FROM public.properties WHERE id = $1::uuid LIMIT 1"

    case Repo.query(sql, [DbUuid.dump!(property_id)]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, map_row(columns, row)}
      _ -> {:error, {:status, 404, %{error: "Property not found"}}}
    end
  end

  defp remove_storage(storage_path) do
    path = storage_path |> to_string() |> String.trim()

    if path == "" do
      {:error, {:status, 500, %{error: "Media path missing"}}}
    else
      case SupabaseStorage.remove_object(@bucket, path) do
        :ok ->
          :ok

        {:error, :failed} ->
          {:error,
           {:status, 502, %{error: "Could not delete media file", code: "storage_delete_failed"}}}

        {:error, :not_configured} ->
          {:error, {:status, 500, %{error: "Server misconfigured"}}}
      end
    end
  end

  defp delete_metadata(media_row, user_id) do
    media_id = Map.get(media_row, "id")
    storage_path = Map.get(media_row, "storage_path")

    case Repo.query("DELETE FROM public.property_media WHERE id = $1::uuid", [DbUuid.dump!(media_id)]) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        _ =
          Repo.query(
            """
            INSERT INTO public.property_media_cleanup_failures
              (media_id, property_id, owner_id, storage_path, error_message)
            VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5)
            """,
            [
              DbUuid.dump!(media_id),
              DbUuid.dump!(Map.get(media_row, "property_id")),
              DbUuid.dump!(user_id),
              storage_path,
              Exception.message(error)
            ]
          )

        {:error,
         {:status, 500,
          %{
            error: "File removed but metadata cleanup failed. Retry shortly.",
            code: "metadata_cleanup_failed"
          }}}
    end
  end

  defp map_row(columns, row), do: Map.new(Enum.zip(columns, row))
end

defmodule Mithril.MobileFunctions.UberTripEstimate do
  @moduledoc false

  def call(_user_id, _body) do
    {:error,
     {:status, 410,
      %{
        error:
          "Uber trip estimates are no longer used. Request GET /bookings/:id/transport-estimate.",
        code: "uber_estimate_removed"
      }}}
  end
end
