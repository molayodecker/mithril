defmodule Mithril.WhatsApp.ChefIntakeTest do
  use ExUnit.Case, async: true
  alias Mithril.WhatsApp.ChefIntake

  test "walks through all eight fields and requires confirmation" do
    {state, text} = ChefIntake.start()
    assert text =~ "Which area"

    values = [
      "East Legon",
      "1",
      "3",
      "2",
      "5",
      "Cooking and shopping",
      "GH₵2000 per month",
      Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
    ]

    {state, text} =
      Enum.reduce(values, {state, text}, fn value, {state, _text} ->
        {next, reply} = ChefIntake.advance(state, value)
        {next, reply}
      end)

    assert state.status == :confirm
    assert text =~ "Reply YES"
    {finished, _reply, answers} = ChefIntake.advance(state, "YES")
    assert finished.status == :completed
    assert answers["chef_type"] == "home_cook"
    assert answers["people"] == 5
    assert answers["location"] == "East Legon"
  end

  test "rejects invalid number without advancing" do
    {state, _} = ChefIntake.start()
    {state, _} = ChefIntake.advance(state, "Accra")
    {state, _} = ChefIntake.advance(state, "1")
    {state, _} = ChefIntake.advance(state, "1")
    {state, _} = ChefIntake.advance(state, "1")
    {unchanged, message} = ChefIntake.advance(state, "zero")
    assert unchanged.step == 4
    assert message =~ "isn't valid"
  end

  test "APPLY cannot switch or advance an active chef enquiry" do
    {state, _} = ChefIntake.start()
    {state, _} = ChefIntake.advance(state, "East Legon")

    {blocked, reply} = ChefIntake.advance(state, "APPLY")
    assert blocked == state
    assert reply =~ "This WhatsApp line is for chef enquiries"
    assert blocked.answers["location"] == "East Legon"
  end

  test "an unfinished chef conversation can restart without carrying answers" do
    {state, _} = ChefIntake.start()
    {state, _} = ChefIntake.advance(state, "East Legon")
    assert state.answers["location"] == "East Legon"

    {restarted, prompt} = ChefIntake.advance(state, "RESTART")
    assert restarted.answers == %{}
    assert restarted.step == 0
    assert prompt =~ "Which area"
  end

  test "can restart at any step" do
    {state, _} = ChefIntake.start()
    {state, _} = ChefIntake.advance(state, "Accra")
    {restarted, _} = ChefIntake.advance(state, "RESTART")
    assert restarted == ChefIntake.initial()
  end
end
