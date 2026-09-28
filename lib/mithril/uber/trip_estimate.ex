defmodule Mithril.Uber.TripEstimate do
  @moduledoc false

  @spec parse_request(map()) :: {:ok, map()} | {:error, String.t()}
  def parse_request(body) when is_map(body) do
    if Map.get(body, "__implemented") == true do
      {:ok, %{cleaner_id: Map.get(body, "cleaner_id")}}
    else
      {:error, "Uber trip estimates are not configured"}
    end
  end

  @spec load_cleaner_origin(term()) :: {:ok, map()} | {:error, :missing}
  def load_cleaner_origin(cleaner_id) do
    if cleaner_id == :implemented do
      {:ok, %{latitude: 0.0, longitude: 0.0}}
    else
      {:error, :missing}
    end
  end

  @spec fetch_estimate(map()) :: {:ok, map()} | {:error, String.t()}
  def fetch_estimate(input) when is_map(input) do
    if Map.get(input, :__implemented) == true do
      {:ok, %{currency_code: "GHS", customer_fee_major: 0}}
    else
      {:error, "Uber trip estimates are not configured"}
    end
  end
end
