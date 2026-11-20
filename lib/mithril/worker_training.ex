defmodule Mithril.WorkerTraining do
  @moduledoc """
  Worker training assignments.

  Operations assigns a catalog course when they record a health action of
  `training`. That row is what Instaclean Pro lists for the worker. A team
  lead assigns a catalog course for someone on their team. The worker lists
  and completes only their own rows.
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

  @spec known_course_key(term()) :: {:ok, String.t()} | {:error, :unknown_course}
  def known_course_key(key) when is_binary(key) do
    key = String.trim(key)

    if Map.has_key?(@courses, key) do
      {:ok, key}
    else
      {:error, :unknown_course}
    end
  end

  def known_course_key(_key), do: {:error, :unknown_course}

  @spec course_title!(String.t()) :: String.t()
  def course_title!(course_key) when is_binary(course_key) do
    Map.fetch!(@courses, course_key)["title"]
  end

  @spec note_with_course(String.t(), String.t() | nil) :: String.t()
  def note_with_course(course_key, nil) when is_binary(course_key) do
    course_title!(course_key)
  end

  def note_with_course(course_key, notes) when is_binary(course_key) and is_binary(notes) do
    "#{course_title!(course_key)}. #{notes}"
  end

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
  Assigns a catalog course for a health case so Instaclean Pro can list it.
  A second send of the same open course leaves the existing row in place.
  Runs inside the caller's transaction.
  """
  @spec assign_for_health_case(binary(), binary(), String.t()) :: :ok
  def assign_for_health_case(case_id, assigned_by, course_key)
      when is_binary(case_id) and is_binary(assigned_by) and is_binary(course_key) do
    case known_course_key(course_key) do
      {:ok, course_key} ->
        assign_known_course(case_id, assigned_by, course_key)

      {:error, :unknown_course} ->
        Repo.rollback(:unknown_course)
    end
  end

  defp assign_known_course(case_id, assigned_by, course_key) do
    case Repo.query("SELECT to_regclass('public.worker_training_assignments')") do
      {:ok, %{rows: [[nil]]}} ->
        Repo.rollback(:training_unavailable)

      {:ok, %{rows: [[_table]]}} ->
        insert_health_assignment(case_id, assigned_by, course_key)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp insert_health_assignment(case_id, assigned_by, course_key) do
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
           [case_id, assigned_by, course_key]
         ) do
      {:ok, %{num_rows: rows}} when rows > 0 ->
        :ok

      {:ok, %{num_rows: 0}} ->
        confirm_open_assignment(case_id, course_key)

      {:error, error} ->
        Repo.rollback({:database, error})
    end
  end

  defp confirm_open_assignment(case_id, course_key) do
    case Repo.query(
           """
           SELECT c.cleaner_id IS NOT NULL,
                  EXISTS (
                    SELECT 1
                    FROM public.worker_training_assignments a
                    WHERE a.worker_user_id = c.cleaner_id
                      AND a.course_key = $2
                      AND a.status = 'assigned'
                  )
           FROM public.cleaner_operations_cases c
           WHERE c.id = $1
           """,
           [case_id, course_key]
         ) do
      {:ok, %{rows: [[true, true]]}} ->
        :ok

      {:ok, %{rows: [[false, _assigned]]}} ->
        Repo.rollback(:worker_missing)

      {:ok, %{rows: []}} ->
        Repo.rollback(:not_found)

      {:ok, %{rows: [[true, false]]}} ->
        Repo.rollback(:training_not_saved)

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

  defp fetch_course_key(key) do
    case known_course_key(key) do
      {:ok, course_key} ->
        {:ok, course_key}

      {:error, :unknown_course} ->
        invalid("unknown_course", "Choose one of the training courses.")
    end
  end

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
