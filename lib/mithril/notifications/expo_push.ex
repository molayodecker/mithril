defmodule Mithril.Notifications.ExpoPush do
  @moduledoc false

  @expo_url "https://exp.host/--/api/v2/push/send"
  @token_regex ~r/^(Expo(nent)?PushToken)\[.+\]$/

  @spec valid_token?(String.t()) :: boolean()
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_regex, token)
  def valid_token?(_), do: false

  @spec send_tokens([String.t()], map()) :: non_neg_integer()
  def send_tokens(tokens, payload) when is_list(tokens) and is_map(payload) do
    tokens
    |> Enum.filter(&valid_token?/1)
    |> Enum.uniq()
    |> Enum.chunk_every(100)
    |> Enum.reduce(0, fn chunk, count ->
      messages =
        Enum.map(chunk, fn token ->
          %{
            to: token,
            title: payload.title,
            body: payload.body,
            sound: "default",
            priority: "high",
            channelId: payload[:channel_id] || "booking_updates",
            data: payload[:data] || %{}
          }
        end)

      case Req.post(@expo_url, json: messages) do
        {:ok, %{status: status}} when status in 200..299 -> count + length(chunk)
        _ -> count
      end
    end)
  end
end
