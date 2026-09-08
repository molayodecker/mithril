defmodule Mithril.DirectVideos do
  @moduledoc """
  Access-controlled candidate video introductions for Instaclean Direct.

  Customers may only read a video for a candidate currently matched to one of
  their placement requests. Direct admins may read or update video metadata for
  active, vetted candidates.
  """

  alias Mithril.Repo

  @match_statuses ~w(suggested selected hired)

  def show_candidate_video(user_id, placement_id, candidate_user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, pid} <- dump_uuid(placement_id),
         {:ok, candidate_id} <- dump_uuid(candidate_user_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT jsonb_build_object(
               'candidateUserId', pcp.user_id,
               'introVideoUrl', pcp.intro_video_url,
               'introVideoThumbnailUrl', pcp.intro_video_thumbnail_url,
               'introVideoTitle', pcp.intro_video_title
             )
             FROM public.placement_requests pr
             JOIN public.placement_matches pm
               ON pm.placement_request_id = pr.id
             JOIN public.placement_candidate_profiles pcp
               ON pcp.user_id = pm.candidate_user_id
             WHERE pr.id = $1
               AND pr.customer_id = $2
               AND pm.candidate_user_id = $3
               AND pm.status = ANY($4::text[])
               AND pcp.intro_video_url IS NOT NULL
             LIMIT 1
             """,
             [pid, uid, candidate_id, @match_statuses]
           ) do
      case result.rows do
        [[video]] -> {:ok, video}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, _error} -> {:error, :database_unavailable}
    end
  end

  def show_admin_candidate_video(user_id, candidate_user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, candidate_id} <- dump_uuid(candidate_user_id),
         :ok <- require_admin(uid),
         :ok <- require_active_candidate(candidate_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT jsonb_build_object(
               'candidateUserId', $1::uuid,
               'introVideoUrl', pcp.intro_video_url,
               'introVideoThumbnailUrl', pcp.intro_video_thumbnail_url,
               'introVideoTitle', pcp.intro_video_title
             )
             FROM (SELECT 1) seed
             LEFT JOIN public.placement_candidate_profiles pcp
               ON pcp.user_id = $1
             LIMIT 1
             """,
             [candidate_id]
           ) do
      [[video]] = result.rows
      {:ok, video}
    else
      :error -> {:error, :not_found}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, _error} -> {:error, :database_unavailable}
    end
  end

  def update_admin_candidate_video(user_id, candidate_user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, candidate_id} <- dump_uuid(candidate_user_id),
         :ok <- require_admin(uid),
         :ok <- require_active_candidate(candidate_id),
         {:ok, video_url} <- normalize_https_url(params["introVideoUrl"], :invalid_video_url),
         {:ok, thumbnail_url} <-
           normalize_https_url(params["introVideoThumbnailUrl"], :invalid_video_thumbnail_url),
         {:ok, title} <- normalize_title(params["introVideoTitle"]),
         {:ok, result} <-
           Repo.query(
             """
             INSERT INTO public.placement_candidate_profiles (
               user_id,
               intro_video_url,
               intro_video_thumbnail_url,
               intro_video_title
             ) VALUES ($1, $2, $3, $4)
             ON CONFLICT (user_id) DO UPDATE SET
               intro_video_url = EXCLUDED.intro_video_url,
               intro_video_thumbnail_url = EXCLUDED.intro_video_thumbnail_url,
               intro_video_title = EXCLUDED.intro_video_title,
               updated_at = now()
             RETURNING jsonb_build_object(
               'candidateUserId', user_id,
               'introVideoUrl', intro_video_url,
               'introVideoThumbnailUrl', intro_video_thumbnail_url,
               'introVideoTitle', intro_video_title
             )
             """,
             [candidate_id, video_url, thumbnail_url, title]
           ) do
      [[video]] = result.rows
      {:ok, video}
    else
      :error -> {:error, :not_found}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, _error} -> {:error, :database_unavailable}
    end
  end

  defp require_admin(uid) do
    case Repo.query(
           "SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = $1 AND role_id = 'admin')",
           [uid]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :forbidden}
      {:error, _error} -> {:error, :database_unavailable}
    end
  end

  defp require_active_candidate(candidate_id) do
    case Repo.query(
           """
           SELECT EXISTS (
             SELECT 1
             FROM public.cleaner_data
             WHERE user_id = $1
               AND verified = true
               AND status = 'active'
           )
           """,
           [candidate_id]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :candidate_unavailable}
      {:error, _error} -> {:error, :database_unavailable}
    end
  end

  defp normalize_https_url(nil, _error), do: {:ok, nil}

  defp normalize_https_url(value, error) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:ok, nil}
    else
      uri = URI.parse(value)

      if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
        {:ok, value}
      else
        {:error, error}
      end
    end
  end

  defp normalize_https_url(_value, error), do: {:error, error}

  defp normalize_title(nil), do: {:ok, nil}

  defp normalize_title(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      String.length(value) <= 120 -> {:ok, value}
      true -> {:error, :video_title_too_long}
    end
  end

  defp normalize_title(_value), do: {:error, :invalid_video_title}

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_value), do: :error
end
