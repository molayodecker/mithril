defmodule Mithril.WorkerTrainingDatabaseTest do
  use ExUnit.Case, async: false

  alias Mithril.Repo
  alias Mithril.WorkerTraining

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to create training tables; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.co_cleaner_relationships (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      lead_cleaner_id uuid NOT NULL,
      co_cleaner_id uuid NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.cleaner_operations_cases (
      id uuid PRIMARY KEY,
      cleaner_id uuid,
      status text
    )
    """)

    install_training_sql!()
    :ok
  end

  test "a team lead recommendation is visible only to that worker and can be finished once" do
    lead_id = insert_user!()
    worker_id = insert_user!()
    outsider_id = insert_user!()

    Repo.query!(
      """
      INSERT INTO public.co_cleaner_relationships (lead_cleaner_id, co_cleaner_id)
      VALUES ($1, $2)
      """,
      [dump!(lead_id), dump!(worker_id)]
    )

    assert {:error, {:status, 403, %{error: "not_your_worker"}}} =
             WorkerTraining.recommend(lead_id, %{
               "workerUserId" => outsider_id,
               "courseKey" => "safety"
             })

    assert {:ok, %{"assignment" => assigned}} =
             WorkerTraining.recommend(lead_id, %{
               "workerUserId" => worker_id,
               "courseKey" => "safety"
             })

    assert assigned["courseKey"] == "safety"
    assert assigned["reason"] == "employer"
    assert assigned["status"] == "assigned"
    assert assigned["title"] == "Safety on the job"
    refute Map.has_key?(assigned, "notes")

    assert {:ok, %{"assignment" => ^assigned}} =
             WorkerTraining.recommend(lead_id, %{
               "workerUserId" => worker_id,
               "courseKey" => "safety"
             })

    assert {:ok, %{"assignments" => [^assigned]}} = WorkerTraining.list(worker_id)
    assert {:ok, %{"assignments" => []}} = WorkerTraining.list(outsider_id)
    assert {:ok, %{"assignments" => []}} = WorkerTraining.list(lead_id)

    assert {:ok, %{"assignment" => completed}} =
             WorkerTraining.complete(worker_id, %{"id" => assigned["id"]})

    assert completed["status"] == "completed"
    assert completed["completedAt"]

    assert {:ok, %{"assignment" => completed_again}} =
             WorkerTraining.complete(worker_id, %{"id" => assigned["id"]})

    assert completed_again["status"] == "completed"
    assert completed_again["completedAt"] == completed["completedAt"]

    assert {:error, {:status, 404, %{error: "training_not_found"}}} =
             WorkerTraining.complete(outsider_id, %{"id" => assigned["id"]})

    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM public.worker_training_assignments WHERE worker_user_id = $1",
        [dump!(worker_id)]
      ).rows

    assert count == 1
  end

  test "a health-case training action assigns job quality once" do
    worker_id = insert_user!()
    admin_id = insert_user!()
    case_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.cleaner_operations_cases (id, cleaner_id, status)
      VALUES ($1, $2, 'open')
      """,
      [dump!(case_id), dump!(worker_id)]
    )

    assert :ok =
             WorkerTraining.assign_for_health_case(dump!(case_id), dump!(admin_id), "job-quality")

    assert :ok =
             WorkerTraining.assign_for_health_case(dump!(case_id), dump!(admin_id), "job-quality")

    assert {:ok, %{"assignments" => [assignment]}} = WorkerTraining.list(worker_id)
    assert assignment["courseKey"] == "job-quality"
    assert assignment["reason"] == "performance"
    assert assignment["status"] == "assigned"
    assert assignment["title"] == "Job quality"
  end

  test "operations can send a chosen course, and a case without a worker is rejected" do
    worker_id = insert_user!()
    admin_id = insert_user!()
    case_id = Ecto.UUID.generate()
    empty_case_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.cleaner_operations_cases (id, cleaner_id, status)
      VALUES ($1, $2, 'open'), ($3, NULL, 'open')
      """,
      [dump!(case_id), dump!(worker_id), dump!(empty_case_id)]
    )

    assert :ok = WorkerTraining.assign_for_health_case(dump!(case_id), dump!(admin_id), "safety")

    assert {:ok, %{"assignments" => [assignment]}} = WorkerTraining.list(worker_id)
    assert assignment["courseKey"] == "safety"
    assert assignment["title"] == "Safety on the job"
    assert assignment["reason"] == "performance"

    assert {:error, :worker_missing} =
             Repo.transaction(fn ->
               WorkerTraining.assign_for_health_case(
                 dump!(empty_case_id),
                 dump!(admin_id),
                 "punctuality"
               )
             end)
  end

  defp install_training_sql! do
    sql =
      File.read!(
        Path.expand(
          "../../priv/repo/sql/direct/20261119120000_worker_training_assignments.sql",
          __DIR__
        )
      )

    for statement <- sql_statements(sql) do
      Repo.query!(statement)
    end
  end

  defp sql_statements(sql) do
    sql
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn statement ->
      statement
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "--")))
      |> Enum.empty?()
    end)
  end

  defp insert_user! do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.users (id) VALUES ($1)", [dump!(id)])

    id
  end

  defp dump!(id), do: Ecto.UUID.dump!(id)
end
