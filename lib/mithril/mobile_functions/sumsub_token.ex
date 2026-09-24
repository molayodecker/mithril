defmodule Mithril.MobileFunctions.SumsubToken do
  @moduledoc false

  alias Mithril.Sumsub.Applicant
  alias Mithril.Sumsub.ApplicantLink
  alias Mithril.Sumsub.Client
  alias Mithril.Sumsub.Config

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    with :ok <- require_credentials(),
         level_name <- Config.level_name(),
         ttl_in_secs <- ttl_in_secs(body),
         applicant <- ensure_applicant(user_id, body),
         :ok <- maybe_persist_link(user_id, applicant.applicant_id, level_name, body),
         {:ok, token_body} <- mint_access_token(user_id, level_name, ttl_in_secs) do
      {:ok,
       %{
         token: Map.get(token_body, "token"),
         userId: user_id,
         levelName: level_name,
         ttlInSecs: ttl_in_secs,
         applicantId: applicant.applicant_id,
         country: Config.country_code(),
         nationality: Config.nationality_code()
       }}
    else
      {:error, :missing_credentials} ->
        {:error, {:status, 500, %{error: "Identity verification is not configured"}}}

      {:error, {:status, _status, _details}} ->
        {:error, {:status, 502, %{error: "Could not start identity verification"}}}
    end
  end

  defp require_credentials do
    case Config.credentials() do
      {:ok, _} -> :ok
      {:error, :missing_credentials} -> {:error, :missing_credentials}
    end
  end

  defp ttl_in_secs(body) do
    raw =
      case Map.get(body, "ttlInSecs") do
        nil -> 600
        value -> value
      end

    value =
      case raw do
        n when is_integer(n) ->
          n

        n when is_float(n) ->
          trunc(n)

        n when is_binary(n) ->
          case Integer.parse(String.trim(n)) do
            {parsed, _} -> parsed
            :error -> 600
          end

        _ ->
          600
      end

    value |> max(60) |> min(3600)
  end

  defp ensure_applicant(user_id, body) do
    Applicant.ensure_for_user(%{
      external_user_id: user_id,
      email: Map.get(body, "email"),
      phone: Map.get(body, "phone"),
      first_name: Map.get(body, "firstName"),
      last_name: Map.get(body, "lastName"),
      dob: Map.get(body, "dob")
    })
  end

  defp maybe_persist_link(user_id, applicant_id, level_name, _body) do
    if present?(applicant_id) do
      ApplicantLink.persist_link(%{
        user_id: user_id,
        applicant_id: applicant_id,
        level_name: level_name,
        country: Config.country_code()
      })
    end

    :ok
  end

  defp mint_access_token(user_id, level_name, ttl_in_secs) do
    path =
      "/resources/accessTokens" <>
        "?userId=#{URI.encode(user_id)}" <>
        "&levelName=#{URI.encode(level_name)}" <>
        "&ttlInSecs=#{ttl_in_secs}"

    Client.post(path, nil)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
