defmodule Mithril.WorkerTraining do
  @moduledoc """
  Worker training assignments.

  Instaclean assigns `job-quality` when operations records a health action of
  `training`. A team lead assigns a catalog course for someone on their team.
  The worker lists and completes only their own rows.
  """

  alias Mithril.DbUuid
  alias Mithril.Repo

  @courses %{
    "job-quality" => %{
      "title" => "Job quality",
      "summary" =>
        "Finish the visit the way the customer expected: the rooms they asked for, a clear walkthrough, and nothing left undone."
    },
    "punctuality" => %{
      "title" => "Showing up on time",
      "summary" =>
        "Arrive when you said you would. If you are running late, tell the customer before the start time."
    },
    "customer-care" => %{
      "title" => "Customer care",
      "summary" =>
        "Greet the customer, listen to what they want changed, and leave private things as you found them."
    },
    "safety" => %{
      "title" => "Safety on the job",
      "summary" =>
        "Keep children, pets, and cleaning products safe. Stop and ask if a task feels unsafe."
    }
  }

  @performance_course "job-quality"

  @spec list(String.t()) :: {:ok, map()} | {:error, term()}
  def list(user_id) when is_binary(user_id) do
    with {:ok, worker_id} <- dump_user(user_id) do
      query_assignments(worker_id)
    end
  end

  def list(_user_id), do: invalid("invalid_worker", "Sign in to view training.")

  @spec complete(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def complete(user_id, body) when is_binary(user_id) and is_map(body) do
    with {:ok, worker_id} <- dump_user(user_id),
         {:ok, assignment_id} <-
           dump_param(
             body["id"] || body["assignmentId"],
             "invalid_assignment",
             "Choose a course to finish."
           ) do
      complete_assignment(worker_id, assignment_id)
    end
  end

  def complete(_user_id, _body), do: {:error, :bad_request}

  @spec recommend(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def recommend(lead_user_id, body) when is_binary(lead_user_id) and is_map(body) do
    with {:ok, course_key} <- fetch_course_key(body["courseKey"] || body["course_key"]),
         {:ok, worker_id} <-
           dump_param(
             body["workerUserId"] || body["worker_user_id"],
             "invalid_worker",
             "Choose a co-worker."
           ),
         :ok <- ensure_other_worker(lead_user_id, worker_id),
         {:ok, lead_id} <- dump_user(lead_user_id) do
      recommend_course(lead_id, worker_id, course_key)
    end
  end

  def recommend(_lead_user_id, _body), do: {:error, :bad_request}

  @doc """
  Assigns the performance course for a health case. Skips when the table is
  not applied yet so an older database can still record the health action.
  Runs inside the caller's transaction.
  """
  @spec assign_for_health_case(binary(), binary()) :: :ok
  def assign_for_health_case(case_id, assigned_by)
      when is_binary(case_id) and is_binary(assigned_by) do
    case Repo.query("SELECT to_regclass('public.worker_training_assignments')") do
      {:ok, %{rows: [[nil]]}} ->
        :ok

      {:ok, %{rows: [[_table]]}} ->
        case Repo.query(
               """
               INSERT INTO public.worker_training_assignments (
                 worker_user_id, course_key, reason, health_case_id, assigned_by_user_id
               )
               SELECT c.cleaner_id, $3, 'performance', c.id, $2
               FROM public.cleaner_operations_cases c
               WHERE c.id = $1
                 AND c.cleaner_id IS NOT NULL
               ON CONFLICT (worker_user_id, course_key) WHERE status = 'assigned'
               DO NOTHING
               """,
               [case_id, assigned_by, @performance_course]
             ) do
          {:ok, _} -> :ok
          {:error, error} -> Repo.rollback({:database, error})
        end

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp query_assignments(worker_id) do
    case Repo.query(
           """
           SELECT id, course_key, reason, status, assigned_at, completed_at
           FROM public.worker_training_assignments
           WHERE worker_user_id = $1
           ORDER BY CASE WHEN status = 'assigned' THEN 0 ELSE 1 END, assigned_at DESC
           """,
           [worker_id]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, %{"assignments" => Enum.map(rows, &assignment_json/1)}}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        unavailable()

      {:error, %Postgrex.Error{}} ->
        invalid("training_not_loaded", "Could not load your training.")
    end
  end

  defp complete_assignment(worker_id, assignment_id) do
    case Repo.query(
           """
           UPDATE public.worker_training_assignments
           SET status = 'completed',
               completed_at = COALESCE(completed_at, now())
           WHERE id = $1
             AND worker_user_id = $2
             AND status IN ('assigned', 'completed')
           RETURNING id, course_key, reason, status, assigned_at, completed_at
           """,
           [assignment_id, worker_id]
         ) do
      {:ok, %{rows: [row]}} ->
        {:ok, %{"assignment" => assignment_json(row)}}

      {:ok, %{rows: []}} ->
        {:error,
         {:status, 404,
          %{error: "training_not_found", message: "That training is no longer available."}}}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        unavailable()

      {:error, %Postgrex.Error{}} ->
        invalid("training_not_saved", "Could not save this course.")
    end
  end

  defp recommend_course(lead_id, worker_id, course_key) do
    case Repo.query(
           """
           SELECT 1
           FROM public.co_cleaner_relationships
           WHERE lead_cleaner_id = $1 AND co_cleaner_id = $2
           """,
           [lead_id, worker_id]
         ) do
      {:ok, %{rows: []}} ->
        {:error,
         {:status, 403,
          %{
            error: "not_your_worker",
            message: "You can recommend training only for someone on your team."
          }}}

      {:ok, %{rows: [_member]}} ->
        insert_employer_assignment(lead_id, worker_id, course_key)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        unavailable()

      {:error, %Postgrex.Error{}} ->
        invalid("training_not_saved", "Could not recommend this course.")
    end
  end

  defp insert_employer_assignment(lead_id, worker_id, course_key) do
    inserted =
      Repo.query(
        """
        INSERT INTO public.worker_training_assignments (
          worker_user_id, course_key, reason, assigned_by_user_id
        )
        VALUES ($1, $2, 'employer', $3)
        ON CONFLICT (worker_user_id, course_key) WHERE status = 'assigned'
        DO NOTHING
        RETURNING id, course_key, reason, status, assigned_at, completed_at
        """,
        [worker_id, course_key, lead_id]
      )

    case inserted do
      {:ok, %{rows: [row]}} ->
        {:ok, %{"assignment" => assignment_json(row)}}

      {:ok, %{rows: []}} ->
        reopen_existing(worker_id, course_key)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        unavailable()

      {:error, %Postgrex.Error{}} ->
        invalid("training_not_saved", "Could not recommend this course.")
    end
  end

  defp reopen_existing(worker_id, course_key) do
    case Repo.query(
           """
           SELECT id, course_key, reason, status, assigned_at, completed_at
           FROM public.worker_training_assignments
           WHERE worker_user_id = $1
             AND course_key = $2
             AND status = 'assigned'
           """,
           [worker_id, course_key]
         ) do
      {:ok, %{rows: [row]}} ->
        {:ok, %{"assignment" => assignment_json(row)}}

      _other ->
        invalid("training_not_saved", "Could not recommend this course.")
    end
  end

  defp assignment_json([id, course_key, reason, status, assigned_at, completed_at]) do
    course = Map.fetch!(@courses, course_key)

    %{
      "id" => DbUuid.encode(id),
      "courseKey" => course_key,
      "title" => course["title"],
      "summary" => course["summary"],
      "reason" => reason,
      "status" => status,
      "assignedAt" => iso8601(assigned_at),
      "completedAt" => iso8601(completed_at)
    }
  end

  defp fetch_course_key(key) when is_binary(key) do
    key = String.trim(key)

    if Map.has_key?(@courses, key) do
      {:ok, key}
    else
      invalid("unknown_course", "Choose one of the training courses.")
    end
  end

  defp fetch_course_key(_key),
    do: invalid("unknown_course", "Choose one of the training courses.")

  defp ensure_other_worker(lead_user_id, worker_id) do
    if DbUuid.equal?(lead_user_id, worker_id) do
      invalid("cannot_recommend_self", "Choose a co-worker on your team.")
    else
      :ok
    end
  end

  defp dump_user(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> {:ok, DbUuid.dump!(uuid)}
      :error -> invalid("invalid_worker", "Sign in to view training.")
    end
  end

  defp dump_param(value, error, message) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, DbUuid.dump!(uuid)}
      :error -> invalid(error, message)
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso8601(value) when is_binary(value), do: value

  defp unavailable do
    {:error,
     {:status, 501, %{error: "training_unavailable", message: "Training is not available yet."}}}
  end

  defp invalid(error, message) do
    {:error, {:status, 400, %{error: error, message: message}}}
  end
end
