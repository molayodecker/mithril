defmodule Mithril.Auth.Phone do
  @moduledoc false

  @e164 ~r/^\+[1-9]\d{7,14}$/

  def normalize(value) when is_binary(value) do
    digits_or_plus =
      value
      |> String.trim()
      |> String.replace(~r/[\s\-().]/, "")

    cond do
      String.contains?(digits_or_plus, "@") ->
        :error

      String.match?(digits_or_plus, @e164) ->
        {:ok, digits_or_plus}

      String.match?(digits_or_plus, ~r/^0\d{9}$/) ->
        {:ok, "+233" <> String.slice(digits_or_plus, 1, 9)}

      String.match?(digits_or_plus, ~r/^233\d{9}$/) ->
        {:ok, "+" <> digits_or_plus}

      String.match?(digits_or_plus, ~r/^\d{8,15}$/) ->
        {:ok, "+" <> digits_or_plus}

      true ->
        :error
    end
  end

  def normalize(_), do: :error
end
