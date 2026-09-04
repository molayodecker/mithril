defmodule Mithril.Direct do
  @moduledoc """
  Instaclean Direct data access and transitions.

  Direct's web application authenticates the Supabase session, then calls this
  API through the server-only Direct gateway. All placement/helper data access
  and authorization lives here while Supabase PostgreSQL remains the temporary
  source of truth.
  """

  require Logger

  alias Mithril.Repo

  @roles ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
  @living_arrangements ~w(live_in live_out flexible)
  @employment_types ~w(full_time part_time flexible)
  @salary_frequencies ~w(hourly daily weekly monthly)

  def list_placements(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT jsonb_build_object(
               'id', id,
               'status', status,
               'role', role,
               'livingArrangement', living_arrangement,
               'employmentType', employment_type,
               'desiredStartDate', desired_start_date,
               'householdAddress', household_address_snapshot,
               'createdAt', created_at
             )
             FROM public.placement_requests
             WHERE customer_id = $1
             ORDER BY created_at DESC
             """,
             [uid]
           ) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, error} -> database_error(error)
    end
  end

  def create_placement(user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- validate_placement(params),
         {:ok, result} <-
           Repo.query(
             """
             INSERT INTO public.placement_requests (
               customer_id,
               status,
               role,
               living_arrangement,
               employment_type,
               desired_start_date,
               salary_min_pesewas,
               salary_max_pesewas,
               salary_frequency,
               household_address_snapshot,
               requirements,
               notes
             ) VALUES (
               $1,
               'submitted',
               $2,
               $3,
               $4,
               NULLIF($5::text, '')::date,
               $6,
               $7,
               NULLIF($8::text, ''),
               $9,
               $10::text::jsonb,
               NULLIF($11::text, '')
             )
             RETURNING id::text
             """,
             [
               uid,
               params["role"],
               params["livingArrangement"],
               params["employmentType"],
               text_or_empty(params["desiredStartDate"]),
               params["salaryMinPesewas"],
               params["salaryMaxPesewas"],
               text_or_empty(params["salaryFrequency"]),
               String.trim(params["householdAddress"]),
               Jason.encode!(params["requirements"] || %{}),
               text_or_empty(params["notes"])
             ]
           ) do
      [[id]] = result.rows
      {:ok, %{id: id}}
    else
      :error -> {:error, :invalid_user}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def get_placement(user_id, placement_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, pid} <- dump_uuid(placement_id),
         {:ok, placement} <- fetch_owned_placement(uid, pid),
         {:ok, candidates} <- fetch_candidates(pid) do
      {:ok, %{placement: placement, candidates: candidates}}
    else
      :error -> {:error, :not_found}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def list_helpers(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, result} <-
           Repo.query(
             """
             SELECT jsonb_build_object(
               'id', id,
               'firstName', first_name,
               'lastName', last_name,
               'phone', phone,
               'source', source,
               'role', role,
               'status', status,
               'liveIn', live_in
             )
             FROM public.household_workers
             WHERE household_owner_id = $1
             ORDER BY created_at DESC
             """,
             [uid]
           ) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, error} -> database_error(error)
    end
  end

  def add_private_helper(user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- validate_private_helper(params),
         {:ok, result} <-
           Repo.query(
             """
             INSERT INTO public.household_workers (
               household_owner_id,
               worker_user_id,
               first_name,
               last_name,
               phone,
               email,
               source,
               role,
               start_date,
               live_in,
               status,
               invitation_status
             ) VALUES (
               $1,
               NULL,
               $2,
               NULLIF($3::text, ''),
               $4,
               NULLIF($5::text, ''),
               'customer_invited',
               NULLIF($6::text, ''),
               NULLIF($7::text, '')::date,
               $8,
               'active',
               'not_sent'
             )
             ON CONFLICT (household_owner_id, phone)
               WHERE worker_user_id IS NULL
             DO UPDATE SET
               first_name = EXCLUDED.first_name,
               last_name = EXCLUDED.last_name,
               email = EXCLUDED.email,
               role = EXCLUDED.role,
               start_date = EXCLUDED.start_date,
               live_in = EXCLUDED.live_in,
               status = 'active',
               updated_at = now()
             RETURNING id::text
             """,
             [
               uid,
               String.trim(params["firstName"]),
               text_or_empty(params["lastName"]),
               String.trim(params["phone"]),
               text_or_empty(params["email"]),
               text_or_empty(params["role"]),
               text_or_empty(params["startDate"]),
               params["liveIn"] == true
             ]
           ) do
      [[id]] = result.rows
      {:ok, %{householdWorkerId: id}}
    else
      :error -> {:error, :invalid_user}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def hire_match(user_id, match_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, mid} <- dump_uuid(match_id) do
      Repo.transaction(fn -> do_hire_match(uid, mid) end)
      |> normalize_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def list_admin_placements(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, result} <-
           Repo.query("""
           SELECT jsonb_build_object(
             'id', id,
             'customerUserId', customer_id,
             'status', status,
             'role', role,
             'householdAddress', household_address_snapshot,
             'createdAt', created_at
           )
           FROM public.placement_requests
           ORDER BY created_at DESC
           LIMIT 100
           """) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def list_admin_candidates(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, result} <-
           Repo.query("""
           SELECT jsonb_build_object(
             'userId', cd.user_id,
             'name', COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               u.email,
               'Provider'
             ),
             'email', u.email,
             'rating', cd.rating,
             'completedJobs', cd.completed_jobs,
             'placementOptIn', COALESCE(pcp.placement_opt_in, false),
             'placementStatus', COALESCE(pcp.placement_status, 'inactive'),
             'desiredRoles', COALESCE(to_jsonb(pcp.desired_roles), '[]'::jsonb)
           )
           FROM public.cleaner_data cd
           JOIN public.users u ON u.id = cd.user_id
           LEFT JOIN public.profiles p ON p.id = cd.user_id
           LEFT JOIN public.placement_candidate_profiles pcp ON pcp.user_id = cd.user_id
           WHERE cd.verified = true
             AND cd.status = 'active'
           ORDER BY COALESCE(cd.rating, 0) DESC, COALESCE(cd.completed_jobs, 0) DESC
           LIMIT 200
           """) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def match_admin_candidate(user_id, placement_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, pid} <- dump_uuid(placement_id),
         {:ok, candidate_id} <- dump_uuid(params["candidateUserId"]),
         :ok <- require_admin(uid) do
      Repo.transaction(fn -> do_match_admin_candidate(pid, candidate_id, params) end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  defp fetch_owned_placement(uid, pid) do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'id', id,
             'role', role,
             'status', status,
             'householdAddress', household_address_snapshot,
             'createdAt', created_at
           )
           FROM public.placement_requests
           WHERE id = $1 AND customer_id = $2
           LIMIT 1
           """,
           [pid, uid]
         ) do
      {:ok, %{rows: [[placement]]}} -> {:ok, placement}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_candidates(pid) do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'matchId', pm.id,
             'candidateUserId', pm.candidate_user_id,
             'firstName', COALESCE(
               NULLIF(btrim(p.firstname), ''),
               NULLIF(split_part(COALESCE(p.fullname, ''), ' ', 1), ''),
               'Helper'
             ),
             'lastInitial', CASE
               WHEN NULLIF(btrim(p.lastname), '') IS NOT NULL THEN upper(left(btrim(p.lastname), 1))
               WHEN array_length(regexp_split_to_array(btrim(COALESCE(p.fullname, '')), '\\s+'), 1) > 1
                 THEN upper(left((regexp_split_to_array(btrim(p.fullname), '\\s+'))[2], 1))
               ELSE ''
             END,
             'avatarUrl', p.avatar_url,
             'yearsExperience', pcp.years_experience,
             'bio', pcp.bio,
             'preferredLanguages', COALESCE(to_jsonb(pcp.preferred_languages), '[]'::jsonb),
             'availableFrom', pcp.available_from,
             'rating', cd.rating,
             'completedJobs', cd.completed_jobs,
             'customerVisibleNote', pm.customer_visible_note,
             'identityVerified', CASE
               WHEN upper(COALESCE(kyc.review_answer, '')) = 'GREEN' THEN true
               WHEN lower(COALESCE(kyc.kyc_status, '')) IN ('verified', 'approved', 'completed') THEN true
               ELSE false
             END,
             'providerVerified', COALESCE(cd.verified, false) AND cd.status = 'active',
             'matchStatus', pm.status
           )
           FROM public.placement_matches pm
           LEFT JOIN public.profiles p ON p.id = pm.candidate_user_id
           LEFT JOIN public.placement_candidate_profiles pcp ON pcp.user_id = pm.candidate_user_id
           LEFT JOIN public.cleaner_data cd ON cd.user_id = pm.candidate_user_id
           LEFT JOIN LATERAL (
             SELECT kp.*
             FROM public.kyc_profiles kp
             WHERE kp.user_id = pm.candidate_user_id
             ORDER BY
               CASE
                 WHEN lower(COALESCE(kp.kyc_status, '')) IN ('', 'not_started')
                   AND kp.review_answer IS NULL
                   AND kp.sumsub_applicant_id IS NULL
                   AND kp.last_event_type IS NULL
                   AND kp.submitted_at IS NULL
                 THEN 1 ELSE 0
               END,
               GREATEST(
                 COALESCE(kp.reviewed_at, 'epoch'::timestamptz),
                 COALESCE(kp.completed_at, 'epoch'::timestamptz),
                 COALESCE(kp.submitted_at, 'epoch'::timestamptz),
                 COALESCE(kp.sumsub_linked_at, 'epoch'::timestamptz),
                 COALESCE(kp.updated_at, 'epoch'::timestamptz),
                 COALESCE(kp.created_at, 'epoch'::timestamptz)
               ) DESC
             LIMIT 1
           ) kyc ON true
           WHERE pm.placement_request_id = $1
             AND pm.status IN ('suggested', 'selected', 'hired')
           ORDER BY pm.created_at ASC
           """,
           [pid]
         ) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> {:error, error}
    end
  end

  defp require_admin(uid) do
    case Repo.query(
           "SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = $1 AND role_id = 'admin')",
           [uid]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp do_match_admin_candidate(pid, candidate_id, params) do
    request =
      one_row_or_rollback(
        """
        SELECT role, status
        FROM public.placement_requests
        WHERE id = $1
        FOR UPDATE
        """,
        [pid],
        :not_found
      )

    [role, status] = request

    if status in ["placed", "cancelled", "expired"] do
      Repo.rollback(:placement_closed)
    end

    provider =
      one_row_or_rollback(
        """
        SELECT verified, status
        FROM public.cleaner_data
        WHERE user_id = $1
        """,
        [candidate_id],
        :candidate_unavailable
      )

    unless provider == [true, "active"] do
      Repo.rollback(:candidate_unavailable)
    end

    profile =
      case Repo.query(
             """
             SELECT placement_opt_in, placement_status, desired_roles
             FROM public.placement_candidate_profiles
             WHERE user_id = $1
             """,
             [candidate_id]
           ) do
        {:ok, %{rows: [row]}} -> row
        {:ok, %{rows: []}} -> [false, "inactive", []]
        {:error, error} -> Repo.rollback({:database, error})
      end

    [opt_in, placement_status, desired_roles] = profile

    needs_consent =
      opt_in != true or placement_status != "available" or role not in (desired_roles || [])

    if needs_consent and params["consentConfirmed"] != true do
      Repo.rollback(:consent_required)
    end

    if needs_consent do
      case Repo.query(
             """
             INSERT INTO public.placement_candidate_profiles (
               user_id, placement_opt_in, placement_status, desired_roles
             ) VALUES ($1, true, 'available', ARRAY[$2]::text[])
             ON CONFLICT (user_id) DO UPDATE SET
               placement_opt_in = true,
               placement_status = 'available',
               desired_roles = ARRAY(
                 SELECT DISTINCT unnest(
                   COALESCE(
                     public.placement_candidate_profiles.desired_roles,
                     ARRAY[]::text[]
                   ) || EXCLUDED.desired_roles
                 )
               ),
               updated_at = now()
             """,
             [candidate_id, role]
           ) do
        {:ok, _} -> :ok
        {:error, error} -> Repo.rollback({:database, error})
      end
    end

    match_id =
      case Repo.query(
             """
             INSERT INTO public.placement_matches (
               placement_request_id,
               candidate_user_id,
               status,
               customer_visible_note
             ) VALUES ($1, $2, 'suggested', NULLIF($3::text, ''))
             ON CONFLICT (placement_request_id, candidate_user_id) DO UPDATE SET
               status = 'suggested',
               customer_visible_note = EXCLUDED.customer_visible_note,
               updated_at = now()
             RETURNING id::text
             """,
             [pid, candidate_id, text_or_empty(params["customerVisibleNote"])]
           ) do
        {:ok, %{rows: [[id]]}} -> id
        {:error, error} -> Repo.rollback({:database, error})
      end

    case Repo.query("UPDATE public.placement_requests SET status = 'shortlisted' WHERE id = $1", [
           pid
         ]) do
      {:ok, _} -> %{matchId: match_id}
      {:error, error} -> Repo.rollback({:database, error})
    end
  end

  defp do_hire_match(uid, mid) do
    [
      request_id,
      candidate_id,
      match_status,
      request_status,
      role,
      desired_start_date,
      salary_frequency,
      living_arrangement
    ] =
      one_row_or_rollback(
        """
        SELECT
          pr.id,
          pm.candidate_user_id,
          pm.status,
          pr.status,
          pr.role,
          pr.desired_start_date,
          pr.salary_frequency,
          pr.living_arrangement
        FROM public.placement_matches pm
        JOIN public.placement_requests pr ON pr.id = pm.placement_request_id
        WHERE pm.id = $1 AND pr.customer_id = $2
        FOR UPDATE OF pr, pm
        """,
        [mid, uid],
        :not_found
      )

    if request_status in ["placed", "cancelled", "expired"] do
      Repo.rollback(:placement_closed)
    end

    unless match_status in ["suggested", "selected"] do
      Repo.rollback(:candidate_unavailable)
    end

    [opt_in, placement_status, desired_roles, verified, provider_status] =
      one_row_or_rollback(
        """
        SELECT
          pcp.placement_opt_in,
          pcp.placement_status,
          pcp.desired_roles,
          cd.verified,
          cd.status
        FROM public.placement_candidate_profiles pcp
        JOIN public.cleaner_data cd ON cd.user_id = pcp.user_id
        WHERE pcp.user_id = $1
        FOR UPDATE OF pcp, cd
        """,
        [candidate_id],
        :candidate_unavailable
      )

    unless opt_in == true and placement_status == "available" and
             role in (desired_roles || []) and verified == true and provider_status == "active" do
      Repo.rollback(:candidate_unavailable)
    end

    [first_name, last_name, phone, email] =
      one_row_or_rollback(
        """
        SELECT
          COALESCE(
            NULLIF(btrim(p.firstname), ''),
            NULLIF(split_part(COALESCE(p.fullname, ''), ' ', 1), ''),
            'Helper'
          ),
          NULLIF(btrim(p.lastname), ''),
          u.phone,
          u.email
        FROM public.users u
        LEFT JOIN public.profiles p ON p.id = u.id
        WHERE u.id = $1
        """,
        [candidate_id],
        :candidate_unavailable
      )

    if not is_binary(phone) or String.trim(phone) == "" do
      Repo.rollback(:candidate_missing_phone)
    end

    household_worker_id =
      case Repo.query(
             """
             SELECT id, id::text
             FROM public.household_workers
             WHERE household_owner_id = $1 AND worker_user_id = $2
             LIMIT 1
             FOR UPDATE
             """,
             [uid, candidate_id]
           ) do
        {:ok, %{rows: [[worker_id, id]]}} ->
          with_query_or_rollback(
            """
            UPDATE public.household_workers
            SET first_name = $2,
                last_name = $3,
                phone = $4,
                email = $5,
                source = 'instaclean_placement',
                placement_request_id = $6,
                placement_match_id = $7,
                role = $8,
                start_date = $9,
                salary_frequency = $10,
                live_in = $11,
                status = 'active',
                invitation_status = 'accepted',
                updated_at = now()
            WHERE id = $1
            """,
            [
              worker_id,
              first_name,
              last_name,
              phone,
              email,
              request_id,
              mid,
              role,
              desired_start_date,
              salary_frequency,
              living_arrangement == "live_in"
            ]
          )

          id

        {:ok, %{rows: []}} ->
          case Repo.query(
                 """
                 INSERT INTO public.household_workers (
                   household_owner_id,
                   worker_user_id,
                   first_name,
                   last_name,
                   phone,
                   email,
                   source,
                   placement_request_id,
                   placement_match_id,
                   role,
                   start_date,
                   salary_frequency,
                   live_in,
                   status,
                   invitation_status
                 ) VALUES (
                   $1, $2, $3, $4, $5, $6,
                   'instaclean_placement', $7, $8, $9, $10, $11, $12,
                   'active', 'accepted'
                 )
                 RETURNING id::text
                 """,
                 [
                   uid,
                   candidate_id,
                   first_name,
                   last_name,
                   phone,
                   email,
                   request_id,
                   mid,
                   role,
                   desired_start_date,
                   salary_frequency,
                   living_arrangement == "live_in"
                 ]
               ) do
            {:ok, %{rows: [[id]]}} -> id
            {:error, error} -> Repo.rollback({:database, error})
          end

        {:error, error} ->
          Repo.rollback({:database, error})
      end

    with_query_or_rollback("UPDATE public.placement_matches SET status = 'hired' WHERE id = $1", [
      mid
    ])

    with_query_or_rollback(
      """
      UPDATE public.placement_matches
      SET status = 'cancelled'
      WHERE placement_request_id = $1
        AND id <> $2
        AND status IN ('suggested', 'selected')
      """,
      [request_id, mid]
    )

    with_query_or_rollback(
      "UPDATE public.placement_requests SET status = 'placed' WHERE id = $1",
      [request_id]
    )

    %{householdWorkerId: household_worker_id}
  end

  defp one_row_or_rollback(sql, params, error) do
    case Repo.query(sql, params) do
      {:ok, %{rows: [row]}} -> row
      {:ok, %{rows: []}} -> Repo.rollback(error)
      {:error, database_error} -> Repo.rollback({:database, database_error})
    end
  end

  defp with_query_or_rollback(sql, params) do
    case Repo.query(sql, params) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback({:database, error})
    end
  end

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, {:database, error}}), do: database_error(error)
  defp normalize_transaction({:error, error}), do: {:error, error}

  defp validate_placement(params) do
    role = params["role"]
    living = params["livingArrangement"]
    employment = params["employmentType"]
    desired_start_date = params["desiredStartDate"]
    frequency = params["salaryFrequency"]
    min_salary = params["salaryMinPesewas"]
    max_salary = params["salaryMaxPesewas"]
    address = params["householdAddress"]
    requirements = params["requirements"] || %{}

    cond do
      role not in @roles ->
        {:error, :invalid_role}

      living not in @living_arrangements ->
        {:error, :invalid_living_arrangement}

      employment not in @employment_types ->
        {:error, :invalid_employment_type}

      not valid_optional_iso_date?(desired_start_date) ->
        {:error, :invalid_desired_start_date}

      not is_nil(frequency) and frequency not in @salary_frequencies ->
        {:error, :invalid_salary_frequency}

      not valid_nonnegative_integer?(min_salary) ->
        {:error, :invalid_salary}

      not valid_nonnegative_integer?(max_salary) ->
        {:error, :invalid_salary}

      is_integer(min_salary) and is_integer(max_salary) and min_salary > max_salary ->
        {:error, :invalid_salary_range}

      not is_binary(address) or byte_size(String.trim(address)) < 3 ->
        {:error, :invalid_address}

      not is_map(requirements) ->
        {:error, :invalid_requirements}

      true ->
        :ok
    end
  end

  defp validate_private_helper(params) do
    first_name = params["firstName"]
    phone = params["phone"]
    role = params["role"]
    start_date = params["startDate"]

    cond do
      not is_binary(first_name) or String.trim(first_name) == "" -> {:error, :invalid_name}
      not is_binary(phone) or byte_size(String.trim(phone)) < 6 -> {:error, :invalid_phone}
      not is_nil(role) and role not in @roles -> {:error, :invalid_role}
      not valid_optional_iso_date?(start_date) -> {:error, :invalid_start_date}
      true -> :ok
    end
  end

  defp valid_nonnegative_integer?(nil), do: true
  defp valid_nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp valid_optional_iso_date?(nil), do: true

  defp valid_optional_iso_date?(value) when is_binary(value) do
    value = String.trim(value)
    value == "" or match?({:ok, _date}, Date.from_iso8601(value))
  end

  defp valid_optional_iso_date?(_value), do: false

  defp text_or_empty(nil), do: ""
  defp text_or_empty(value) when is_binary(value), do: String.trim(value)
  defp text_or_empty(value), do: to_string(value)

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_value), do: :error

  defp database_error(error) do
    Logger.error("Direct database operation failed: #{Exception.message(error)}")
    {:error, :database_unavailable}
  end
end
