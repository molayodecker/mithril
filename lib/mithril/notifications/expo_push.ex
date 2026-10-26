defmodule Mithril.Notifications.ExpoPush do
  @moduledoc false

  @expo_url "https://exp.host/--/api/v2/push/send"
  @token_regex ~r/^(Expo(nent)?PushToken)\[.+\]$/

  @spec valid_token?(String.t()) :: boolean()
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_regex, token)
  def valid_token?(_), do: false

  defp maybe_put(message, _key, nil), do: message
  defp maybe_put(message, key, value), do: Map.put(message, key, value)

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
            sound: payload[:sound] || "default",
            priority: "high",
            channelId: payload[:channel_id] || "booking_updates",
            data: payload[:data] || %{}
          }
          |> maybe_put(:badge, payload[:badge])
          |> maybe_put(:interruptionLevel, payload[:interruption_level])
        end)

      case Req.post(@expo_url, json: messages) do
        {:ok, %{status: status, body: %{"data" => tickets}}}
        when status in 200..299 and is_list(tickets) ->
          count + Enum.count(tickets, &(Map.get(&1, "status") == "ok"))

        _ ->
          count
      end
    end)
  end
end
