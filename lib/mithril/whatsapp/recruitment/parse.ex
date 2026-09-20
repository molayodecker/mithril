defmodule Mithril.WhatsApp.Recruitment.Parse do
  @moduledoc false

  def normalize_command(message) do
    t =
      message
      |> String.trim()
      |> String.upcase()
      |> String.replace(~r/\s+/u, " ")

    cond do
      t in ["APPLY", "START"] ->
        "APPLY"

      t in ["RESTART", "RESET"] ->
        "RESTART"

      t == "BACK" ->
        "BACK"

      t == "SKIP" ->
        "SKIP"

      t in ["STATUS", "PROGRESS"] ->
        "STATUS"

      t in ["HELP", "?"] ->
        "HELP"

      t in ["SUBMIT", "SEND"] ->
        "SUBMIT"

      t in ["CONTINUE", "RESUME", "NEXT QUESTION"] ->
        "CONTINUE"

      t in ["MORE", "NEXT"] ->
        "MORE"

      t in ["LINK", "URL"] ->
        "LINK"

      t in ["CODE", "GET CODE", "WEB CODE", "CONTINUE CODE", "PASTE CODE"] ->
        "CODE"

      t in ["SIGNUP", "SIGN UP", "CREATE ACCOUNT", "LOGIN", "LOG IN", "VERIFY PHONE", "PHONE"] ->
        "SIGNUP"

      t in ["WEB", "WEBSITE", "SITE", "BROWSER", "ONLINE"] ->
        "WEB"

      true ->
        nil
    end
  end

  def effective_message(params) do
    payload = string_param(params, "ButtonPayload") || string_param(params, "buttonPayload")
    button = string_param(params, "ButtonText") || string_param(params, "buttonText")
    body = string_param(params, "Body") || ""

    cond do
      payload != "" -> payload
      button != "" -> button
      true -> body
    end
  end

  def strip_whatsapp_prefix(value) when is_binary(value) do
    value
    |> String.replace(~r/^whatsapp:/i, "")
    |> String.trim()
  end

  def strip_whatsapp_prefix(_), do: ""

  def validate_email(email) do
    t = String.trim(email)
    String.match?(t, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) and String.length(t) <= 320
  end

  def normalize_email(nil), do: nil

  def normalize_email(email) do
    t = email |> to_string() |> String.trim()
    if t == "", do: nil, else: String.downcase(t)
  end

  def normalize_ghana_phone(input) when is_binary(input) do
    raw = input |> String.trim() |> String.replace(~r/[\s-]/, "")

    cond do
      raw == "" or String.contains?(raw, "@") ->
        nil

      true ->
        digits = if String.starts_with?(raw, "+"), do: String.slice(raw, 1..-1//1), else: raw

        cond do
          not String.match?(digits, ~r/^\d+$/) ->
            nil

          String.starts_with?(digits, "233") and String.length(digits) >= 12 ->
            "+" <> digits

          String.starts_with?(digits, "0") and String.length(digits) == 10 ->
            "+233" <> String.slice(digits, 1..-1//1)

          String.length(digits) == 9 ->
            "+233" <> digits

          true ->
            nil
        end
    end
  end

  def normalize_ghana_phone(_), do: nil

  def parse_menu_choice(message, max_option) do
    case Integer.parse(String.trim(message)) do
      {n, ""} when n >= 1 and n <= max_option -> n
      _ -> nil
    end
  end

  def yes_no_choice(message) do
    t =
      message
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/[.!?，。]+$/u, "")
      |> String.trim()

    cond do
      t in ~w(1 yes y yeah yep yup sure ok okay true) -> 1
      t in ~w(2 no n nope nah never false) -> 2
      true -> parse_menu_choice(message, 2)
    end
  end

  def terms_accept?(message) do
    t = String.downcase(String.trim(message))
    t in ["1", "accept", "yes", "agree", "i agree"] or parse_menu_choice(message, 1) == 1
  end

  def background_consent?(message) do
    t = String.downcase(String.trim(message))
    t in ["1", "accept", "yes", "consent", "i consent"] or parse_menu_choice(message, 1) == 1
  end

  def equipment_choice(message) do
    t =
      message
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/u, " ")

    cond do
      t in ["1", "all equipment", "all"] -> 1
      t in ["2", "some"] -> 2
      t in ["3", "need provided", "provided"] -> 3
      true -> parse_menu_choice(message, 3)
    end
  end

  def parse_multi_select(message, max_option, opts \\ []) do
    trimmed = String.trim(message)
    none_option = Keyword.get(opts, :none_option)
    collapsed = trimmed |> String.downcase() |> String.replace(~r/\s+/u, " ")

    cond do
      trimmed == "" ->
        nil

      collapsed in ["all", "all of them", "everything", "every"] ->
        1..max_option
        |> Enum.reject(&(&1 == none_option))
        |> case do
          [] -> nil
          nums -> nums
        end

      true ->
        parts =
          trimmed
          |> String.split(~r/[,，]/u)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        nums =
          Enum.reduce_while(parts, [], fn part, acc ->
            case Integer.parse(part) do
              {n, ""} when n >= 1 and n <= max_option -> {:cont, [n | acc]}
              _ -> {:halt, :invalid}
            end
          end)

        case nums do
          :invalid -> nil
          list -> list |> Enum.uniq() |> Enum.sort()
        end
    end
  end

  def parse_future_date(input) do
    t = String.trim(input)
    today = Date.utc_today()
    lower = t |> String.downcase() |> String.replace(~r/\s+/u, " ")

    cond do
      t == "" ->
        nil

      lower in ["today", "now", "asap", "immediately"] ->
        Date.to_iso8601(today)

      lower == "tomorrow" ->
        today |> Date.add(1) |> Date.to_iso8601()

      match?({:ok, _}, Date.from_iso8601(t)) ->
        {:ok, date} = Date.from_iso8601(t)
        if Date.compare(date, today) == :lt, do: nil, else: Date.to_iso8601(date)

      true ->
        case __MODULE__.TimexParser.try_date(t) do
          {:ok, date} ->
            if Date.compare(date, today) == :lt, do: nil, else: Date.to_iso8601(date)

          :error ->
            nil
        end
    end
  end

  def string_param(params, key) when is_binary(key) do
    raw =
      Map.get(params, key) ||
        Enum.find_value(params, fn
          {k, v} when is_atom(k) -> if Atom.to_string(k) == key, do: v
          _ -> nil
        end)

    case raw do
      value when is_binary(value) -> String.trim(value)
      value when is_number(value) -> to_string(value)
      _ -> ""
    end
  end

  defmodule TimexParser do
    @moduledoc false

    def try_date(text) do
      case DateTime.from_iso8601(text) do
        {:ok, datetime, _} -> {:ok, DateTime.to_date(datetime)}
        _ -> parse_english(text)
      end
    end

    defp parse_english(text) do
      months = %{
        "january" => 1,
        "february" => 2,
        "march" => 3,
        "april" => 4,
        "may" => 5,
        "june" => 6,
        "july" => 7,
        "august" => 8,
        "september" => 9,
        "october" => 10,
        "november" => 11,
        "december" => 12,
        "jan" => 1,
        "feb" => 2,
        "mar" => 3,
        "apr" => 4,
        "jun" => 6,
        "jul" => 7,
        "aug" => 8,
        "sep" => 9,
        "oct" => 10,
        "nov" => 11,
        "dec" => 12
      }

      case Regex.run(~r/^(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})$/, String.trim(text)) do
        [_, day, month_name, year] ->
          month = Map.get(months, String.downcase(month_name))

          with month when is_integer(month) <- month,
               {d, ""} <- Integer.parse(day),
               {y, ""} <- Integer.parse(year),
               {:ok, date} <- Date.new(y, month, d) do
            {:ok, date}
          else
            _ -> :error
          end

        _ ->
          :error
      end
    end
  end
end
