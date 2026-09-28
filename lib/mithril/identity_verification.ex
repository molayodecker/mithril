defmodule Mithril.IdentityVerification do
  @moduledoc false

  alias Mithril.Repo

  @type source :: :kyc_profiles | :cleaner_data | nil
  @type status ::
          :verified | :pending | :rejected | :unverified | :legacy_verified

  @type result :: %{
          verified: boolean(),
          source: source(),
          status: status()
        }

  @spec resolve(String.t()) :: {:ok, result()} | {:error, term()}
  def resolve(user_id) when is_binary(user_id) do
    with {:ok, kyc_rows} <- load_kyc_profiles(user_id) do
      if kyc_rows != [] do
        {:ok, resolve_from_kyc(kyc_rows)}
      else
        resolve_legacy_cleaner(user_id)
      end
    end
  end

  @spec empty_legacy_kyc_placeholder?(map()) :: boolean()
  def empty_legacy_kyc_placeholder?(row) when is_map(row) do
    status = row |> Map.get("kyc_status", "") |> to_string() |> String.downcase()

    if status not in ["not_started", ""] do
      false
    else
      not present?(row, "review_answer") and
        not present?(row, "sumsub_applicant_id") and
        not present?(row, "last_event_type") and
        not present?(row, "submitted_at")
    end
  end

  @spec kyc_row_verified?(map()) :: boolean()
  def kyc_row_verified?(row) when is_map(row) do
    kyc_status = row |> Map.get("kyc_status", "") |> to_string() |> String.downcase()
    review_answer = row |> Map.get("review_answer", "") |> to_string() |> String.upcase()

    review_answer == "GREEN" or kyc_status in ["verified", "approved"]
  end

  @spec derive_kyc_verification_status(map()) :: status()
  def derive_kyc_verification_status(row) when is_map(row) do
    if kyc_row_verified?(row) do
      :verified
    else
      kyc_status = row |> Map.get("kyc_status", "") |> to_string() |> String.downcase()
      review_answer = row |> Map.get("review_answer", "") |> to_string() |> String.upcase()

      cond do
        review_answer == "RED" or kyc_status in ["rejected", "declined"] ->
          :rejected

        kyc_status in ["pending", "init", "queued"] or review_answer == "YELLOW" ->
          :pending

        true ->
          :unverified
      end
    end
  end

  defp load_kyc_profiles(user_id) do
    sql = """
    SELECT kyc_status, review_answer, updated_at, sumsub_applicant_id, last_event_type, submitted_at
    FROM public.kyc_profiles
    WHERE user_id = $1::uuid
    ORDER BY updated_at DESC NULLS LAST
    LIMIT 10
    """

    case Repo.query(sql, [user_id]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             kyc_status,
                             review_answer,
                             updated_at,
                             sumsub_applicant_id,
                             last_event_type,
                             submitted_at
                           ] ->
           %{
             "kyc_status" => kyc_status,
             "review_answer" => review_answer,
             "updated_at" => updated_at,
             "sumsub_applicant_id" => sumsub_applicant_id,
             "last_event_type" => last_event_type,
             "submitted_at" => submitted_at
           }
         end)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_from_kyc(kyc_rows) do
    sorted =
      Enum.sort_by(
        kyc_rows,
        fn row ->
          case Map.get(row, "updated_at") do
            %DateTime{} = dt ->
              DateTime.to_unix(dt, :millisecond)

            %NaiveDateTime{} = ndt ->
              NaiveDateTime.diff(ndt, ~N[1970-01-01 00:00:00], :millisecond)

            _ ->
              0
          end
        end,
        :desc
      )

    authoritative =
      Enum.find(sorted, fn row -> not empty_legacy_kyc_placeholder?(row) end) ||
        List.first(sorted)

    %{
      verified: kyc_row_verified?(authoritative),
      source: :kyc_profiles,
      status: derive_kyc_verification_status(authoritative)
    }
  end

  defp resolve_legacy_cleaner(user_id) do
    sql = """
    SELECT verified
    FROM public.cleaner_data
    WHERE user_id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [user_id]) do
      {:ok, %{rows: [[true]]}} ->
        {:ok, %{verified: true, source: :cleaner_data, status: :legacy_verified}}

      {:ok, %{rows: _}} ->
        {:ok, %{verified: false, source: nil, status: :unverified}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp present?(row, key) do
    row
    |> Map.get(key)
    |> case do
      value when is_binary(value) -> String.trim(value) != ""
      %DateTime{} -> true
      %NaiveDateTime{} -> true
      _ -> false
    end
  end
end
