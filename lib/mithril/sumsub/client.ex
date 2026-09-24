defmodule Mithril.Sumsub.Client do
  @moduledoc false

  alias Mithril.Sumsub.Config

  @user_agent "instaclean-mithril/1.0"

  @spec get(String.t()) :: {:ok, map()} | {:error, {:status, non_neg_integer(), binary()}}
  def get(path_with_query) when is_binary(path_with_query) do
    request("GET", path_with_query, "")
  end

  @spec post(String.t(), map() | nil) ::
          {:ok, map()} | {:error, {:status, non_neg_integer(), binary()}}
  def post(path_with_query, body \\ nil) do
    body_str =
      case body do
        nil -> ""
        value when is_map(value) -> Jason.encode!(value)
        value when is_binary(value) -> value
      end

    request("POST", path_with_query, body_str)
  end

  defp request(method, path_with_query, body_str) do
    with {:ok, creds} <- Config.credentials() do
      ts = System.system_time(:second) |> Integer.to_string()
      payload = ts <> method <> path_with_query <> body_str

      signature =
        :crypto.mac(:hmac, :sha256, creds.secret_key, payload)
        |> Base.encode16(case: :lower)

      url = Config.base_url() <> path_with_query

      headers = [
        {"accept", "application/json"},
        {"content-type", "application/json"},
        {"user-agent", @user_agent},
        {"x-app-token", creds.app_token},
        {"x-app-access-ts", ts},
        {"x-app-access-sig", signature}
      ]

      req_opts = [headers: headers, decode_body: true]

      result =
        case method do
          "GET" -> Req.get(url, req_opts)
          "POST" -> Req.post(url, Keyword.put(req_opts, :body, body_str))
        end

      case result do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          details =
            cond do
              is_binary(body) -> String.slice(body, 0, 2000)
              is_map(body) -> Jason.encode!(body)
              true -> ""
            end

          {:error, {:status, status, details}}

        {:error, _} ->
          {:error, {:status, 502, "Sumsub unavailable"}}
      end
    else
      {:error, :missing_credentials} ->
        {:error, {:status, 500, "Missing Sumsub credentials"}}
    end
  end
end
