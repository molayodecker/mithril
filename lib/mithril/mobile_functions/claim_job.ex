defmodule Mithril.MobileFunctions.ClaimJob do
  @moduledoc false

  alias Mithril.MobileGateway
  alias Mithril.Repo

  @job_id_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    job_id = body |> Map.get("job_id", "") |> to_string() |> String.trim()

    cond do
      job_id == "" ->
        {:error, {:status, 400, %{success: false, error: "Missing job_id"}}}

      not Regex.match?(@job_id_regex, job_id) ->
        {:error, {:status, 400, %{success: false, error: "Invalid job_id"}}}

      true ->
        case MobileGateway.with_user_transaction(user_id, fn ->
               case Repo.query("SELECT public.claim_job($1::uuid, $2::uuid)", [job_id, user_id]) do
                 {:ok, %{rows: [[result]]}} when is_map(result) ->
                   {:ok, result}

                 {:ok, %{rows: _rows}} ->
                   {:error, :no_result}

                 {:error, error} ->
                   {:error, error}
               end
             end) do
          {:ok, result} ->
            decode_claim_result(result)

          {:error, :no_result} ->
            {:error, {:status, 500, %{success: false, error: "No result"}}}

          {:error, %Postgrex.Error{}} ->
            {:error, {:status, 400, %{success: false, error: "claim_failed"}}}

          {:error, _} ->
            {:error, {:status, 500, %{success: false, error: "No result"}}}
        end
    end
  end

  defp decode_claim_result(%{"success" => true, "job" => job}) do
    {:ok, %{success: true, job: job}}
  end

  defp decode_claim_result(%{"success" => true} = result) do
    {:ok, Map.take(result, ["success", "job"])}
  end

  defp decode_claim_result(%{"success" => false, "error" => error}) do
    {:error, {:status, 409, %{success: false, error: error || "claim_failed"}}}
  end

  defp decode_claim_result(_) do
    {:error, {:status, 500, %{success: false, error: "No result"}}}
  end
end
