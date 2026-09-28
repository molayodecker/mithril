defmodule Mithril.Sumsub.SyncLookup do
  @moduledoc false

  @type kyc_profile :: %{
          optional(String.t()) => String.t() | nil
        }

  @spec build_paths([kyc_profile()], map() | nil) :: [String.t()]
  def build_paths(kyc_profiles, cleaner_application \\ nil) when is_list(kyc_profiles) do
    sorted =
      kyc_profiles
      |> Enum.sort_by(&profile_decision_time_ms/1, :desc)

    paths =
      Enum.reduce(sorted, [], fn profile, acc ->
        acc
        |> push_applicant_paths(
          Map.get(profile, "sumsub_applicant_id"),
          Map.get(profile, "sumsub_external_user_id")
        )
      end)

    paths
    |> push_applicant_paths(
      cleaner_application && Map.get(cleaner_application, "sumsub_applicant_id"),
      cleaner_application && Map.get(cleaner_application, "sumsub_external_user_id")
    )
    |> uniq_paths()
  end

  @spec parse_applicant_envelope(map()) :: %{
          applicant_id: String.t() | nil,
          review_status: String.t() | nil,
          review_answer: String.t() | nil
        }
  def parse_applicant_envelope(applicant) when is_map(applicant) do
    applicant_id =
      case Map.get(applicant, "id") do
        id when is_binary(id) -> id
        _ -> nil
      end

    review = Map.get(applicant, "review") || %{}

    review_status =
      case Map.get(review, "reviewStatus") do
        status when is_binary(status) -> status
        _ -> nil
      end

    review_result = Map.get(review, "reviewResult") || %{}

    review_answer =
      case Map.get(review_result, "reviewAnswer") do
        answer when is_binary(answer) -> answer
        _ -> nil
      end

    %{
      applicant_id: applicant_id,
      review_status: review_status,
      review_answer: review_answer
    }
  end

  defp push_applicant_paths(paths, applicant_id, external_user_id) do
    paths
    |> maybe_push_applicant_id(applicant_id)
    |> maybe_push_external_user_id(external_user_id)
  end

  defp maybe_push_applicant_id(paths, applicant_id) do
    stored = applicant_id |> to_string() |> String.trim()

    if stored != "" do
      paths ++ ["/resources/applicants/#{URI.encode(stored)}/one"]
    else
      paths
    end
  end

  defp maybe_push_external_user_id(paths, external_user_id) do
    stored = external_user_id |> to_string() |> String.trim()

    if stored != "" do
      paths ++ ["/resources/applicants/-;externalUserId=#{URI.encode(stored)}/one"]
    else
      paths
    end
  end

  defp uniq_paths(paths) do
    {_, uniq} =
      Enum.reduce(paths, {MapSet.new(), []}, fn path, {seen, acc} ->
        if MapSet.member?(seen, path) do
          {seen, acc}
        else
          {MapSet.put(seen, path), acc ++ [path]}
        end
      end)

    uniq
  end

  defp profile_decision_time_ms(profile) do
    decision_ms =
      [
        Map.get(profile, "reviewed_at"),
        Map.get(profile, "completed_at"),
        Map.get(profile, "submitted_at"),
        Map.get(profile, "sumsub_linked_at")
      ]
      |> Enum.map(&parse_time_ms/1)
      |> case do
        [] -> 0
        values -> Enum.max(values)
      end

    if decision_ms > 0 do
      decision_ms
    else
      max(
        parse_time_ms(Map.get(profile, "updated_at")),
        parse_time_ms(Map.get(profile, "created_at"))
      )
    end
  end

  defp parse_time_ms(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
      _ -> 0
    end
  end

  defp parse_time_ms(_), do: 0
end
