defmodule Mithril.WhatsApp.ChefIntake do
  @moduledoc """
  Pure conversation flow for customer chef enquiries over WhatsApp.

  A webhook adapter must persist state per phone, validate Twilio signatures,
  and submit the final payload to an authenticated/authorized Direct intake API.
  This module does not persist or submit enquiries.
  """

  @questions [
    {"location", "Which area in Ghana do you need the chef?"},
    {"chef_type", "What type of chef? Reply: 1 Home cook, 2 Personal chef, 3 Professional chef, 4 Event chef, 5 Meal prep chef, 6 Pastry chef."},
    {"cuisine", "What cuisine? Reply: 1 Ghanaian/local, 2 Continental/international, 3 Both, 4 Special dietary meals."},
    {"arrangement", "What arrangement? Reply: 1 Live-in, 2 Live-out, 3 Part-time, 4 Occasional."},
    {"people", "How many people will the chef cook for? Enter a number."},
    {"duties", "What duties do you need? For example: cooking, groceries, meal planning."},
    {"budget", "What is your budget in GH₵? Include per day/week/month."},
    {"start_date", "When should the chef start? Reply with a date (YYYY-MM-DD)."}
  ]

  @types %{"1" => "home_cook", "2" => "personal_chef", "3" => "professional_chef",
           "4" => "event_chef", "5" => "meal_prep_chef", "6" => "pastry_chef"}
  @cuisines %{"1" => "ghanaian", "2" => "continental", "3" => "both", "4" => "special_dietary"}
  @arrangements %{"1" => "live_in", "2" => "live_out", "3" => "part_time", "4" => "occasional"}

  def initial, do: %{step: 0, answers: %{}, status: :in_progress}

  def start do
    {initial(), "Welcome to Instaclean Chef Services! 👨🏾‍🍳\n" <> question(0)}
  end

  @doc """
  Advances a persisted conversation. Returns {state, reply} for incomplete
  steps or {state, reply, completed_answers} after explicit confirmation.
  The caller must durably persist state before sending the reply and must
  ensure exactly-once submission before reporting success.
  """
  def advance(_state, body) when not is_binary(body), do: start()

  def advance(state, body) when is_map(state) do
    response = String.trim(body)

    cond do
      String.upcase(response) == "RESTART" ->
        start()

      state.status == :completed ->
        {state, "Your enquiry is complete. Reply RESTART to begin again."}

      state.status == :confirm ->
        confirm(state, String.upcase(response))

      state.status == :in_progress and is_integer(state.step) and state.step in 0..7 ->
        record_answer(state, response)

      true ->
        start()
    end
  end

  defp record_answer(state, response) do
    {field, _} = Enum.at(@questions, state.step)

    case normalize(field, response) do
      {:ok, answer} ->
        answers = Map.put(state.answers, field, answer)
        next = state.step + 1

        if next == length(@questions) do
          updated = %{state | step: next, answers: answers, status: :confirm}
          {updated, summary(answers) <> "\nReply YES to submit or RESTART to start over."}
        else
          {%{state | step: next, answers: answers}, question(next)}
        end

      :error ->
        {state, "Sorry, that answer isn't valid.\n" <> question(state.step)}
    end
  end

  defp confirm(state, "YES") do
    completed = %{state | status: :completed}
    {completed, "Your chef enquiry is ready for submission.", state.answers}
  end

  defp confirm(state, _), do: {state, "Reply YES to submit or RESTART to begin again."}

  defp question(step), do: @questions |> Enum.at(step) |> elem(1)

  defp normalize("chef_type", value), do: pick(@types, value)
  defp normalize("cuisine", value), do: pick(@cuisines, value)
  defp normalize("arrangement", value), do: pick(@arrangements, value)

  defp normalize("people", value) do
    case Integer.parse(value) do
      {number, ""} when number >= 1 and number <= 1000 -> {:ok, number}
      _ -> :error
    end
  end

  defp normalize("start_date", value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> if Date.compare(date, Date.utc_today()) == :lt, do: :error, else: {:ok, value}
      _ -> :error
    end
  end

  defp normalize(_field, value) when byte_size(value) > 0 and byte_size(value) <= 500,
    do: {:ok, value}

  defp normalize(_field, _value), do: :error

  defp pick(options, value) do
    case Map.fetch(options, value) do
      {:ok, result} -> {:ok, result}
      :error -> :error
    end
  end

  defp summary(answers) do
    [
      "Please review your chef enquiry:",
      "Location: #{answers["location"]}",
      "Chef: #{answers["chef_type"]}",
      "Cuisine: #{answers["cuisine"]}",
      "Arrangement: #{answers["arrangement"]}",
      "People: #{answers["people"]}",
      "Duties: #{answers["duties"]}",
      "Budget: #{answers["budget"]}",
      "Start: #{answers["start_date"]}"
    ]
    |> Enum.join("\n")
  end
end
