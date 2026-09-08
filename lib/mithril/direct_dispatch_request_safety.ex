defmodule Mithril.DirectDispatchRequestSafety do
  @moduledoc "Server-side validation for customer-created Direct dispatch requests."

  alias Mithril.DirectDispatch

  @minimum_lead_seconds 60

  def create_urgent_request(user_id, params) when is_map(params) do
    with {:ok, needed_by} <- parse_needed_by(params["neededBy"]),
         :ok <- ensure_future_request(needed_by) do
      DirectDispatch.create_urgent_request(user_id, params)
    end
  end

  defp parse_needed_by(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_request}
    end
  end

  defp parse_needed_by(_), do: {:error, :invalid_request}

  defp ensure_future_request(needed_by) do
    minimum = DateTime.add(DateTime.utc_now(), @minimum_lead_seconds, :second)

    if DateTime.compare(needed_by, minimum) == :gt,
      do: :ok,
      else: {:error, :needed_by_past}
  end
end
