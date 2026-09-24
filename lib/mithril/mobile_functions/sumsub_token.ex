defmodule Mithril.MobileFunctions.SumsubToken do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.Sumsub.Applicant
  alias Mithril.Sumsub.ApplicantLink
  alias Mithril.Sumsub.Client
  alias Mithril.Sumsub.Config

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    with :ok <- require_credentials(),
         level_name <- Config.level_name(),
         ttl_in_secs <- ttl_in_secs(body),
         applicant <- ensure_applicant(user_id),
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

  defp ensure_applicant(user_id) do
    identity = load_account_identity(user_id)

    Applicant.ensure_for_user(%{
      external_user_id: user_id,
      email: identity.email,
      phone: identity.phone,
      first_name: identity.first_name,
      last_name: identity.last_name
    })
  end

  defp load_account_identity(user_id) do
    {email, phone} =
      case Repo.query("SELECT email, phone FROM public.users WHERE id = $1::uuid LIMIT 1", [
             user_id
           ]) do
        {:ok, %{rows: [[email, phone]]}} -> {present_or_nil(email), present_or_nil(phone)}
        _ -> {nil, nil}
      end

    {first_name, last_name} =
      case Repo.query(
             "SELECT firstname, lastname FROM public.profiles WHERE id = $1::uuid LIMIT 1",
             [user_id]
           ) do
        {:ok, %{rows: [[first_name, last_name]]}} ->
          {present_or_nil(first_name), present_or_nil(last_name)}

        _ ->
          {nil, nil}
      end

    %{email: email, phone: phone, first_name: first_name, last_name: last_name}
  end

  defp present_or_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_or_nil(_), do: nil

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
