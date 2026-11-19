defmodule Mithril.SqlTime do
  @moduledoc """
  Parses PostgreSQL time values, including the HH:MM values sent by mobile clients.
  """

  @spec parse(term()) :: {:ok, Time.t()} | {:error, atom()}
  def parse(%Time{} = time), do: {:ok, time}

  def parse(value) when is_binary(value) do
    value = String.trim(value)

    case Time.from_iso8601(value) do
      {:ok, time} ->
        {:ok, time}

      _ ->
        if String.match?(value, ~r/^\d{2}:\d{2}$/) do
          Time.from_iso8601(value <> ":00")
        else
          {:error, :invalid_format}
        end
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
