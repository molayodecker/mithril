defmodule Mithril.Twilio.MessageLog do
  @moduledoc false

  require Logger

  alias Mithril.DirectAdminWhatsApp

  @default_page_size 50
  @max_page_size 100
  @sid_pattern ~r/\A[A-Za-z0-9]{2,64}\z/
  @page_token_pattern ~r/\A[A-Za-z0-9]{1,200}\z/

  def list(user_id, params) when is_map(params) do
    with :ok <- authorize(user_id) do
      fetch_page(params)
    end
  end

  def list(_user_id, _params), do: {:error, :invalid_request}

  @doc false
  def fetch_page(params) when is_map(params) do
    with {:ok, query} <- query_params(params),
         {:ok, sid, token} <- credentials() do
      request(sid, token, query)
    end
  end

  @doc false
  def query_params(params) when is_map(params) do
    with {:ok, page_size} <- page_size(params),
         {:ok, page_token} <- page_token(params),
         {:ok, to} <- address(params, ["to", "To"]),
         {:ok, from} <- address(params, ["from", "From"]) do
      {:ok,
       %{"PageSize" => page_size}
       |> maybe_put("PageToken", page_token)
       |> maybe_put("To", to)
       |> maybe_put("From", from)}
    end
  end

  defp authorize(user_id) when is_binary(user_id), do: DirectAdminWhatsApp.require_admin(user_id)
  defp authorize(_user_id), do: {:error, :forbidden}

  defp request(sid, token, query) do
    options =
      [
        url: "https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json",
        auth: {:basic, "#{sid}:#{token}"},
        params: query
      ]
      |> Keyword.merge(Application.get_env(:mithril, :twilio_req_options, []))

    case Req.get(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_page(body)

      {:ok, %{status: status}} ->
        Logger.error("Twilio message log request failed status=#{status}")
        {:error, :twilio_unavailable}

      {:error, reason} ->
        Logger.error("Twilio message log request failed reason=#{inspect(reason)}")
        {:error, :twilio_unavailable}
    end
  end

  defp decode_page(%{"messages" => messages} = body) when is_list(messages) do
    {:ok,
     %{
       messages: Enum.map(messages, &message/1),
       nextPageToken: next_page_token(body["next_page_uri"])
     }}
  end

  defp decode_page(_), do: {:error, :twilio_unavailable}

  defp message(row) when is_map(row) do
    %{
      sid: row["sid"],
      from: row["from"],
      to: row["to"],
      body: row["body"],
      status: row["status"],
      direction: row["direction"],
      errorCode: row["error_code"],
      errorMessage: row["error_message"],
      dateSent: row["date_sent"],
      dateCreated: row["date_created"],
      numSegments: row["num_segments"]
    }
  end

  defp message(_), do: %{}

  defp next_page_token(uri) when is_binary(uri) do
    case uri |> URI.parse() |> Map.get(:query) do
      query when is_binary(query) ->
        case URI.decode_query(query) do
          %{"PageToken" => token} when is_binary(token) and token != "" -> token
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp next_page_token(_), do: nil

  defp credentials do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)

    cond do
      not present?(sid) or not present?(token) -> {:error, :twilio_not_configured}
      not String.match?(sid, @sid_pattern) -> {:error, :twilio_not_configured}
      true -> {:ok, sid, token}
    end
  end

  defp page_size(params) do
    case first_present(params, ["pageSize", "page_size", "PageSize"]) do
      nil ->
        {:ok, @default_page_size}

      value ->
        case Integer.parse(to_string(value)) do
          {size, ""} when size in 1..@max_page_size -> {:ok, size}
          _ -> {:error, :invalid_request}
        end
    end
  end

  defp page_token(params) do
    case first_present(params, ["pageToken", "page_token", "PageToken"]) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        token = String.trim(value)

        cond do
          token == "" -> {:ok, nil}
          String.match?(token, @page_token_pattern) -> {:ok, token}
          true -> {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp address(params, keys) do
    case first_present(params, keys) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        address = String.trim(value)

        cond do
          address == "" -> {:ok, nil}
          String.length(address) > 42 -> {:error, :invalid_request}
          String.match?(address, ~r/[[:space:]]/u) -> {:error, :invalid_request}
          true -> {:ok, address}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp first_present(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Map.put(query, key, value)

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false
end
