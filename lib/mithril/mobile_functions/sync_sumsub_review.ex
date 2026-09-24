defmodule Mithril.MobileFunctions.SyncSumsubReview do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.Sumsub.CleanerApplicationLookup
  alias Mithril.Sumsub.Client
  alias Mithril.Sumsub.Config
  alias Mithril.Sumsub.Reconcile
  alias Mithril.Sumsub.SyncLookup

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, _body) when is_binary(user_id) do
    with :ok <- require_credentials(),
         {:ok, cleaner_app} <- load_cleaner_application(user_id),
         {:ok, profiles} <- load_kyc_profiles(user_id) do
      subject = inferred_subject(cleaner_app)
      paths = SyncLookup.build_paths(profiles, cleaner_app)
      cleaner_application_id = cleaner_app && Map.get(cleaner_app, "id")

      cond do
        paths == [] ->
          {:ok, not_created_payload(subject, cleaner_application_id)}

        true ->
          case fetch_applicant_json(paths) do
            {:ok, applicant_json} ->
              parsed = SyncLookup.parse_applicant_envelope(applicant_json)

              build_sync_payload(
                user_id,
                subject,
                cleaner_app,
                cleaner_application_id,
                profiles,
                parsed,
                applicant_json
              )

            {:not_found} ->
              {:ok, not_found_payload(subject, cleaner_application_id)}

            {:error, _status, _details} ->
              {:error, {:status, 502, %{error: "Could not sync identity review"}}}
          end
      end
    end
  end

  defp require_credentials do
    case Config.credentials() do
      {:ok, _} ->
        :ok

      {:error, :missing_credentials} ->
        {:error, {:status, 500, %{error: "Identity verification is not configured"}}}
    end
  end

  defp load_cleaner_application(user_id) do
    case CleanerApplicationLookup.find_latest(%{user_id: user_id}) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:ok, nil}
      {:error, _} -> {:error, {:status, 502, %{error: "Could not load identity records"}}}
    end
  end

  defp load_kyc_profiles(user_id) do
    sql = """
    SELECT id, sumsub_applicant_id, sumsub_external_user_id, cleaner_application_id,
           submitted_at, reviewed_at, completed_at, sumsub_linked_at, updated_at, created_at
    FROM public.kyc_profiles
    WHERE user_id = $1::uuid
    ORDER BY updated_at DESC
    LIMIT 25
    """

    case Repo.query(sql, [user_id]) do
      {:ok, %{columns: columns, rows: rows}} ->
        {:ok, Enum.map(rows, fn row -> Map.new(Enum.zip(columns, row)) end)}

      {:error, _} ->
        {:error, {:status, 502, %{error: "Could not load identity records"}}}
    end
  end

  defp inferred_subject(nil), do: "customer"
  defp inferred_subject(_cleaner_app), do: "cleaner"

  defp fetch_applicant_json([path | rest]) do
    case Client.get(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, {:status, 404, _details}} ->
        case fetch_applicant_json(rest) do
          {:ok, body} -> {:ok, body}
          other -> other
        end

      {:error, {:status, status, details}} ->
        {:error, status, details}
    end
  end

  defp fetch_applicant_json([]), do: {:not_found}

  defp build_sync_payload(
         user_id,
         subject,
         _cleaner_app,
         cleaner_application_id,
         profiles,
         parsed,
         applicant_json
       ) do
    if present?(parsed.applicant_id) and not present?(parsed.review_status) do
      {:ok,
       %{
         ok: true,
         synced: false,
         skipped: true,
         reason: "sumsub_status_unavailable",
         subject: subject,
         applicantId: parsed.applicant_id,
         reviewStatus: nil,
         reviewAnswer: nil,
         kycStatus: nil,
         verificationStatus: nil,
         cleanerApplicationId: cleaner_application_id
       }}
    else
      cleaner_application_persist_id =
        cleaner_application_id || first_cleaner_application_id(profiles)

      case Reconcile.persist_applicant_snapshot(%{
             user_id: user_id,
             applicant_id: parsed.applicant_id,
             review_status: parsed.review_status,
             review_answer: parsed.review_answer,
             applicant_json: applicant_json,
             cleaner_application_id: cleaner_application_persist_id,
             profiles: profiles
           }) do
        {:skipped, skipped} ->
          {:ok,
           %{
             ok: true,
             synced: false,
             skipped: true,
             reason: skipped.reason,
             subject: subject,
             applicantId: parsed.applicant_id,
             reviewStatus: parsed.review_status,
             reviewAnswer: parsed.review_answer,
             kycStatus: skipped.kyc_status,
             verificationStatus: skipped.verification_status,
             cleanerApplicationId: cleaner_application_id
           }}

        {:ok, persist} ->
          persist_errors =
            case persist.persist_errors do
              [] -> nil
              errors -> errors
            end

          {:ok,
           %{
             ok: true,
             synced: true,
             skipped: false,
             subject: subject,
             applicantId: parsed.applicant_id,
             reviewStatus: parsed.review_status,
             reviewAnswer: parsed.review_answer,
             kycStatus: persist.kyc_status,
             verificationStatus: persist.verification_status,
             reused: false,
             persistErrors: persist_errors,
             cleanerApplicationId: cleaner_application_id
           }}
      end
    end
  end

  defp not_created_payload(subject, cleaner_application_id) do
    %{
      ok: false,
      synced: false,
      skipped: true,
      subject: subject,
      applicantId: nil,
      reviewStatus: nil,
      reviewAnswer: nil,
      kycStatus: "not_started",
      verificationStatus: nil,
      reused: false,
      failureCode: "SUMSUB_APPLICANT_NOT_CREATED",
      code: "SUMSUB_APPLICANT_NOT_CREATED",
      nextStep: "start_verification",
      cleanerApplicationId: cleaner_application_id
    }
  end

  defp not_found_payload(subject, cleaner_application_id) do
    %{
      ok: false,
      synced: false,
      skipped: false,
      subject: subject,
      applicantId: nil,
      reviewStatus: nil,
      reviewAnswer: nil,
      failureCode: "SUMSUB_APPLICANT_NOT_FOUND",
      code: "SUMSUB_APPLICANT_NOT_FOUND",
      kycStatus: "not_started",
      verificationStatus: nil,
      nextStep: "restart_verification",
      message: "Stored Sumsub linkage is stale or Sumsub applicant was deleted",
      cleanerApplicationId: cleaner_application_id
    }
  end

  defp first_cleaner_application_id(profiles) do
    Enum.find_value(profiles, fn profile ->
      case Map.get(profile, "cleaner_application_id") do
        id when is_binary(id) ->
          trimmed = String.trim(id)
          if trimmed == "", do: nil, else: trimmed

        _ ->
          nil
      end
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
