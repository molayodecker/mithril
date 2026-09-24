defmodule Mithril.Sumsub.Reconcile do
  @moduledoc false

  alias Mithril.Repo

  @spec derive_kyc_profile_kyc_status(String.t() | nil, String.t() | nil) :: String.t()
  def derive_kyc_profile_kyc_status(review_answer, review_status) do
    review_answer_upper = review_answer |> to_string() |> String.upcase()

    cond do
      review_answer_upper == "GREEN" -> "completed"
      review_answer_upper == "RED" -> "rejected"
      true ->
        normalized =
          review_status
          |> to_string()
          |> String.downcase()
          |> String.replace(~r/[\s_-]+/, "")

        cond do
          normalized == "" -> "started"
          normalized == "init" -> "started"
          String.contains?(normalized, "pending") -> "pending"
          String.contains?(normalized, "queued") -> "pending"
          String.contains?(normalized, "precheck") -> "pending"
          String.contains?(normalized, "onhold") -> "pending"
          String.contains?(normalized, "awaitingservice") -> "pending"
          String.contains?(normalized, "awaitinguser") -> "pending"
          String.contains?(normalized, "completed") -> "completed"
          String.contains?(normalized, "approve") -> "completed"
          String.contains?(normalized, "reject") -> "rejected"
          String.contains?(normalized, "declin") -> "rejected"
          true -> "submitted"
        end
    end
  end

  @spec map_kyc_profile_status_to_verification_status(String.t()) :: String.t()
  def map_kyc_profile_status_to_verification_status(kyc_profile_status) do
    normalized = kyc_profile_status |> to_string() |> String.downcase()

    cond do
      normalized in ["completed", "approved"] -> "verified"
      normalized in ["rejected", "failed", "declined"] -> "rejected"
      normalized in ["started", "not_started", "init"] -> "unverified"
      normalized in ["pending", "submitted", "on_hold"] -> "pending"
      true -> "unverified"
    end
  end

  @spec persist_applicant_snapshot(map()) ::
          {:ok, map()} | {:skipped, map()} | {:error, map()}
  def persist_applicant_snapshot(opts) when is_map(opts) do
    user_id = Map.get(opts, :user_id)
    applicant_id = Map.get(opts, :applicant_id)
    review_status = Map.get(opts, :review_status)
    review_answer = Map.get(opts, :review_answer)
    applicant_json = Map.get(opts, :applicant_json) || %{}
    profiles = Map.get(opts, :profiles) || []
    cleaner_application_id = Map.get(opts, :cleaner_application_id)

    if present?(applicant_id) and not present?(review_status) do
      {:skipped,
       %{
         reason: "sumsub_status_unavailable",
         kyc_status: nil,
         verification_status: nil,
         persist_errors: ["sumsub_status_unavailable: refusing to persist null reviewStatus"]
       }}
    else
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      kyc_status_db = derive_kyc_profile_kyc_status(review_answer, review_status)
      verification_status = map_kyc_profile_status_to_verification_status(kyc_status_db)
      fetched_id = applicant_id |> to_string() |> String.trim()
      external_from_sumsub = read_external_user_id(applicant_json)
      level_name = read_level_name(applicant_json)
      persist_errors = []

      target_kyc =
        profiles
        |> Enum.find(fn profile ->
          (Map.get(profile, "sumsub_applicant_id") || "") |> String.trim() == fetched_id
        end) || List.first(profiles)

      persist_errors =
        if is_nil(target_kyc) or not present?(Map.get(target_kyc, "id")) do
          persist_errors ++ ["kyc_profiles: no matching row to update for this user"]
        else
          persist_errors
        end

      persist_errors =
        if target_kyc && Map.get(target_kyc, "id") do
          case update_kyc_profile(
                 target_kyc,
                 kyc_status_db,
                 review_answer,
                 fetched_id,
                 external_from_sumsub,
                 level_name,
                 now
               ) do
            :ok -> persist_errors
            {:error, message} -> persist_errors ++ ["kyc_profiles: #{message}"]
          end
        else
          persist_errors
        end

      persist_errors =
        if present?(cleaner_application_id) do
          persist_errors
          |> persist_cleaner_application(
            cleaner_application_id,
            review_answer,
            review_status,
            fetched_id,
            external_from_sumsub,
            level_name,
            user_id,
            now
          )
        else
          persist_errors
        end

      {:ok,
       %{
         kyc_status: kyc_status_db,
         verification_status: verification_status,
         persist_errors: persist_errors
       }}
    end
  end

  defp persist_cleaner_application(
         persist_errors,
         cleaner_application_id,
         review_answer,
         review_status,
         fetched_id,
         external_from_sumsub,
         level_name,
         user_id,
         now
       ) do
    app_kyc_status = derive_cleaner_application_kyc_status(review_answer)

    app_params = [
      app_kyc_status,
      review_answer,
      review_status,
      if(fetched_id != "", do: fetched_id, else: nil),
      external_from_sumsub,
      level_name,
      now,
      cleaner_application_id
    ]

    persist_errors =
      case Repo.query(
             """
             UPDATE public.cleaner_applications SET
               kyc_status = $1,
               kyc_review_answer = $2,
               kyc_review_status = $3,
               sumsub_applicant_id = COALESCE($4, sumsub_applicant_id),
               sumsub_external_user_id = COALESCE($5, sumsub_external_user_id),
               sumsub_level_name = COALESCE($6, sumsub_level_name),
               updated_at = $7::timestamptz
             WHERE id = $8::uuid
             """,
             app_params
           ) do
        {:ok, _} -> persist_errors
        {:error, error} -> persist_errors ++ ["cleaner_applications: #{Exception.message(error)}"]
      end

    cv_status = map_to_cleaner_verification_row_status(review_answer)

    case Repo.query(
           """
           INSERT INTO public.cleaner_verifications (id, status)
           VALUES ($1::uuid, $2)
           ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status
           """,
           [user_id, cv_status]
         ) do
      {:ok, _} -> persist_errors
      {:error, error} -> persist_errors ++ ["cleaner_verifications: #{Exception.message(error)}"]
    end
  end

  defp update_kyc_profile(
         target_kyc,
         kyc_status_db,
         review_answer,
         fetched_id,
         external_from_sumsub,
         level_name,
         now
       ) do
    prev_applicant = (Map.get(target_kyc, "sumsub_applicant_id") || "") |> String.trim()
    linked_at = Map.get(target_kyc, "sumsub_linked_at")
    applicant_changed = prev_applicant == "" or prev_applicant != fetched_id

    reviewed_at =
      review_answer
      |> to_string()
      |> String.upcase()
      |> case do
        "GREEN" -> now
        "RED" -> now
        _ -> nil
      end

    sumsub_linked_at =
      cond do
        applicant_changed -> now
        is_binary(linked_at) and String.trim(linked_at) != "" -> linked_at
        true -> now
      end

    case Repo.query(
           """
           UPDATE public.kyc_profiles SET
             kyc_status = $1,
             review_answer = $2,
             reviewed_at = COALESCE($3::timestamptz, reviewed_at),
             sumsub_applicant_id = COALESCE(NULLIF($4, ''), sumsub_applicant_id),
             sumsub_external_user_id = COALESCE($5, sumsub_external_user_id),
             level_name = COALESCE($6, level_name),
             sumsub_linked_at = COALESCE($7::timestamptz, sumsub_linked_at),
             updated_at = $8::timestamptz
           WHERE id = $9::uuid
           """,
           [
             kyc_status_db,
             review_answer,
             reviewed_at,
             fetched_id,
             external_from_sumsub,
             level_name,
             sumsub_linked_at,
             now,
             Map.get(target_kyc, "id")
           ]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp derive_cleaner_application_kyc_status(review_answer) do
    case review_answer |> to_string() |> String.upcase() do
      "GREEN" -> "completed"
      "RED" -> "rejected"
      _ -> "pending"
    end
  end

  defp map_to_cleaner_verification_row_status(review_answer) do
    case review_answer |> to_string() |> String.upcase() do
      "GREEN" -> "approved"
      "RED" -> "rejected"
      _ -> "pending"
    end
  end

  defp read_external_user_id(applicant) do
    direct = Map.get(applicant, "externalUserId")

    cond do
      is_binary(direct) ->
        trimmed = String.trim(direct)
        if trimmed != "", do: trimmed, else: nil

      true ->
        info = Map.get(applicant, "info") || %{}
        nested = Map.get(info, "externalUserId")

        if is_binary(nested) do
          trimmed = String.trim(nested)
          if trimmed != "", do: trimmed, else: nil
        else
          nil
        end
    end
  end

  defp read_level_name(applicant) do
    fixed = Map.get(applicant, "fixedInfo") || %{}

    cond do
      is_binary(Map.get(fixed, "levelName")) ->
        trimmed = String.trim(fixed["levelName"])
        if trimmed != "", do: trimmed, else: nil

      true ->
        review = Map.get(applicant, "review") || %{}
        level = Map.get(review, "levelName")

        if is_binary(level) do
          trimmed = String.trim(level)
          if trimmed != "", do: trimmed, else: nil
        else
          nil
        end
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
