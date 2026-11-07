defmodule Mithril.PayoutNameMatch do
  @moduledoc false

  @doc """
  True when the two names are the same person, or when either name is blank.

  A blank name is not treated as a mismatch. Comparison ignores case, accents,
  punctuation, and token order, and allows a small typo when the token counts match.
  """
  def names_match?(left, right) do
    profile = normalize(left)
    payout = normalize(right)

    cond do
      profile == "" or payout == "" -> true
      profile == payout -> true
      true -> tokens_match?(tokens(profile), tokens(payout))
    end
  end

  def names_mismatch?(left, right), do: not names_match?(left, right)

  @doc false
  def normalize(name) when is_binary(name) do
    name
    |> String.replace(~r/[\x{200B}-\x{200D}\x{FEFF}\x{00A0}]/u, " ")
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def normalize(_), do: ""

  defp tokens(name) do
    name |> String.split(" ", trim: true)
  end

  defp tokens_match?(left, right) when length(left) != length(right), do: false

  defp tokens_match?(left, right) do
    Enum.zip(Enum.sort(left), Enum.sort(right))
    |> Enum.all?(fn {profile_token, payout_token} ->
      profile_token == payout_token or
        levenshtein(profile_token, payout_token) <= max_typo_distance(profile_token)
    end)
  end

  defp max_typo_distance(token) do
    length = String.length(token)

    cond do
      length <= 3 -> 0
      length <= 5 -> 1
      true -> 2
    end
  end

  defp levenshtein(left, right) when left == right, do: 0
  defp levenshtein("", right), do: String.length(right)
  defp levenshtein(left, ""), do: String.length(left)

  defp levenshtein(left, right) do
    source = String.graphemes(left)
    target = String.graphemes(right)
    previous = Enum.to_list(0..length(target))

    source
    |> Enum.with_index(1)
    |> Enum.reduce(previous, fn {source_char, source_index}, row ->
      target
      |> Enum.with_index(1)
      |> Enum.reduce([source_index], fn {target_char, target_index}, current ->
        insert_cost = hd(current) + 1
        delete_cost = Enum.at(row, target_index) + 1

        replace_cost =
          Enum.at(row, target_index - 1) + if(source_char == target_char, do: 0, else: 1)

        [Enum.min([insert_cost, delete_cost, replace_cost]) | current]
      end)
      |> Enum.reverse()
    end)
    |> List.last()
  end
end
