defmodule Mithril.Sumsub.ApplicantLink do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.Sumsub.CleanerApplicationLookup
  alias Mithril.Sumsub.Config

  @spec persist_link(map()) :: :ok
  def persist_link(input) when is_map(input) do
    user_id = Map.get(input, :user_id)
    applicant_id = Map.get(input, :applicant_id)

    if present?(user_id) and present?(applicant_id) do
      level_name = Map.get(input, :level_name, Config.level_name())
      country = Map.get(input, :country, Config.country_code())
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      cleaner_application =
        case CleanerApplicationLookup.find_latest(%{user_id: user_id}) do
          {:ok, row} -> row
          _ -> nil
        end

      cleaner_application_id = cleaner_application && Map.get(cleaner_application, "id")

      persist_cleaner_application_link(
        cleaner_application,
        user_id,
        applicant_id,
        level_name,
        now
      )

      upsert_kyc_profile(user_id, applicant_id, cleaner_application_id, level_name, country, now)
    end

    :ok
  end

  defp upsert_kyc_profile(user_id, applicant_id, cleaner_application_id, level_name, country, now) do
    global_row = fetch_kyc_by_applicant(applicant_id)
    user_row = fetch_latest_kyc_for_user(user_id)
    row_to_update = global_row || reusable_user_row(user_row, applicant_id)

    if row_to_update do
      patch =
        build_link_update(
          row_to_update,
          user_id,
          applicant_id,
          cleaner_application_id,
          level_name,
          country,
          now
        )

      _ =
        Repo.query(
          """
          UPDATE public.kyc_profiles SET
            user_id = $1::uuid,
            sumsub_applicant_id = $2,
            sumsub_external_user_id = $3,
            cleaner_application_id = $4::uuid,
            level_name = $5,
            country_code = $6,
            kyc_status = $7,
            submitted_at = COALESCE(submitted_at, $8::timestamptz),
            sumsub_linked_at = $9::timestamptz,
            updated_at = $10::timestamptz
          WHERE id = $11::uuid
          """,
          [
            user_id,
            applicant_id,
            user_id,
            cleaner_application_id,
            level_name,
            country,
            patch.kyc_status,
            patch.submitted_at,
            patch.sumsub_linked_at,
            now,
            Map.get(row_to_update, "id")
          ]
        )
    else
      case Repo.query(
             """
             INSERT INTO public.kyc_profiles (
               user_id, subject_type, cleaner_application_id,
               sumsub_applicant_id, sumsub_external_user_id,
               level_name, country_code, kyc_status,
               submitted_at, sumsub_linked_at, updated_at
             ) VALUES (
               $1::uuid, 'customer', $2::uuid,
               $3, $4, $5, $6, 'started',
               $7::timestamptz, $7::timestamptz, $7::timestamptz
             )
             ON CONFLICT (sumsub_applicant_id) DO NOTHING
             """,
             [user_id, cleaner_application_id, applicant_id, user_id, level_name, country, now]
           ) do
        {:ok, %{num_rows: 0}} ->
          raced_row = fetch_kyc_by_applicant(applicant_id)

          if raced_row do
            patch =
              build_link_update(
                raced_row,
                user_id,
                applicant_id,
                cleaner_application_id,
                level_name,
                country,
                now
              )

            _ =
              Repo.query(
                """
                UPDATE public.kyc_profiles SET
                  user_id = $1::uuid,
                  sumsub_applicant_id = $2,
                  sumsub_external_user_id = $3,
                  cleaner_application_id = $4::uuid,
                  level_name = $5,
                  country_code = $6,
                  kyc_status = $7,
                  submitted_at = COALESCE(submitted_at, $8::timestamptz),
                  sumsub_linked_at = $9::timestamptz,
                  updated_at = $10::timestamptz
                WHERE id = $11::uuid
                """,
                [
                  user_id,
                  applicant_id,
                  user_id,
                  cleaner_application_id,
                  level_name,
                  country,
                  patch.kyc_status,
                  patch.submitted_at,
                  patch.sumsub_linked_at,
                  now,
                  Map.get(raced_row, "id")
                ]
              )
          end

        _ ->
          :ok
      end
    end
  end

  defp persist_cleaner_application_link(nil, _user_id, _applicant_id, _level_name, _now),
    do: :ok

  defp persist_cleaner_application_link(
         cleaner_application,
         user_id,
         applicant_id,
         level_name,
         now
       ) do
    previous_applicant =
      cleaner_application
      |> Map.get("sumsub_applicant_id")
      |> to_string()
      |> String.trim()

    applicant_changed = previous_applicant != "" and previous_applicant != applicant_id

    _ =
      Repo.query(
        """
        UPDATE public.cleaner_applications SET
          kyc_provider = 'sumsub',
          sumsub_applicant_id = $1,
          sumsub_external_user_id = $2,
          sumsub_level_name = $3,
          kyc_status = CASE WHEN $4 THEN 'not_started' ELSE kyc_status END,
          kyc_review_answer = CASE WHEN $4 THEN NULL ELSE kyc_review_answer END,
          kyc_review_status = CASE WHEN $4 THEN NULL ELSE kyc_review_status END,
          kyc_completed_at = CASE WHEN $4 THEN NULL ELSE kyc_completed_at END,
          kyc_last_event_at = CASE WHEN $4 THEN NULL ELSE kyc_last_event_at END,
          updated_at = $5::timestamptz
        WHERE id = $6::uuid
        """,
        [
          applicant_id,
          user_id,
          level_name,
          applicant_changed,
          now,
          Map.get(cleaner_application, "id")
        ]
      )

    :ok
  end

  defp reusable_user_row(nil, _applicant_id), do: nil

  defp reusable_user_row(row, applicant_id) do
    previous_applicant =
      row
      |> Map.get("sumsub_applicant_id")
      |> to_string()
      |> String.trim()

    if previous_applicant in ["", applicant_id], do: row, else: nil
  end

  defp build_link_update(
         row,
         user_id,
         applicant_id,
         cleaner_application_id,
         level_name,
         country,
         now
       ) do
    prev_applicant = (Map.get(row, "sumsub_applicant_id") || "") |> String.trim()
    applicant_changed = prev_applicant == "" or prev_applicant != applicant_id

    kyc_done =
      not applicant_changed and
        case Map.get(row, "kyc_status") do
          status when is_binary(status) -> String.trim(status) != ""
          _ -> false
        end

    submitted_done =
      not applicant_changed and
        case Map.get(row, "submitted_at") do
          value when is_binary(value) -> String.trim(value) != ""
          _ -> false
        end

    existing_linked_at =
      case Map.get(row, "sumsub_linked_at") do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: nil, else: trimmed

        _ ->
          nil
      end

    sumsub_linked_at =
      if applicant_changed or is_nil(existing_linked_at), do: now, else: existing_linked_at

    %{
      user_id: user_id,
      applicant_id: applicant_id,
      cleaner_application_id: cleaner_application_id,
      level_name: level_name,
      country: country,
      kyc_status: if(kyc_done, do: Map.get(row, "kyc_status"), else: "started"),
      submitted_at: if(submitted_done, do: Map.get(row, "submitted_at"), else: now),
      sumsub_linked_at: sumsub_linked_at
    }
  end

  defp fetch_kyc_by_applicant(applicant_id) do
    sql = """
    SELECT id, kyc_status, submitted_at, sumsub_applicant_id, sumsub_linked_at
    FROM public.kyc_profiles
    WHERE sumsub_applicant_id = $1
    LIMIT 1
    """

    query_one(sql, [applicant_id])
  end

  defp fetch_latest_kyc_for_user(user_id) do
    sql = """
    SELECT id, kyc_status, submitted_at, sumsub_applicant_id, sumsub_linked_at
    FROM public.kyc_profiles
    WHERE user_id = $1::uuid
    ORDER BY updated_at DESC
    LIMIT 1
    """

    query_one(sql, [user_id])
  end

  defp query_one(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{columns: columns, rows: [row]}} -> Map.new(Enum.zip(columns, row))
      _ -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
