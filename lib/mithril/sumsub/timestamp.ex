defmodule Mithril.Sumsub.Timestamp do
  @moduledoc false

  # Postgrex encodes `timestamptz` parameters as `%DateTime{}`.
  # An ISO8601 string raises DBConnection.EncodeError and the request becomes a 500.

  @spec utc_now() :: DateTime.t()
  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @spec cast(term()) :: DateTime.t() | nil
  def cast(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)

  def cast(%NaiveDateTime{} = value) do
    value |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:microsecond)
  end

  def cast(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, datetime, _offset} ->
            DateTime.truncate(datetime, :microsecond)

          _ ->
            case NaiveDateTime.from_iso8601(trimmed) do
              {:ok, naive} -> cast(naive)
              _ -> nil
            end
        end
    end
  end

  def cast(_), do: nil
end
