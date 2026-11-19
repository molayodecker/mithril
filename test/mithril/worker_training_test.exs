defmodule Mithril.WorkerTrainingTest do
  use ExUnit.Case, async: true

  alias Mithril.WorkerTraining

  test "rejects a course that is not in the catalog before any database call" do
    assert {:error, {:status, 400, body}} =
             WorkerTraining.recommend(Ecto.UUID.generate(), %{
               "workerUserId" => Ecto.UUID.generate(),
               "courseKey" => "photoshop"
             })

    assert body.error == "unknown_course"
    refute Map.has_key?(body, "notes")
  end

  test "rejects recommending training to yourself" do
    lead_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{error: "cannot_recommend_self"}}} =
             WorkerTraining.recommend(lead_id, %{
               "workerUserId" => lead_id,
               "courseKey" => "safety"
             })
  end

  test "rejects completing a training id that is not a uuid" do
    assert {:error, {:status, 400, %{error: "invalid_assignment"}}} =
             WorkerTraining.complete(Ecto.UUID.generate(), %{"id" => "course-1"})
  end
end
