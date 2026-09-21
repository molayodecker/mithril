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
             'id', pr.id,
             'customerUserId', pr.customer_id,
             'customerName', COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               NULLIF(btrim(u.email), ''),
               NULLIF(btrim(u.phone), ''),
               'Customer'
             ),
             'customerEmail', u.email,
             'customerPhone', u.phone,
             'status', pr.status,
             'role', pr.role,
             'livingArrangement', pr.living_arrangement,
             'employmentType', pr.employment_type,
             'desiredStartDate', pr.desired_start_date,
             'householdAddress', pr.household_address_snapshot,
             'salaryMinPesewas', pr.salary_min_pesewas,
             'salaryMaxPesewas', pr.salary_max_pesewas,
             'salaryFrequency', pr.salary_frequency,
             'notes', pr.notes,
             'shortlistCount', COALESCE(matches.shortlist_count, 0),
             'shortlistUserIds', COALESCE(matches.shortlist_user_ids, '[]'::jsonb),
             'createdAt', pr.created_at
           )
           FROM public.placement_requests pr
           LEFT JOIN public.users u ON u.id = pr.customer_id
           LEFT JOIN public.profiles p ON p.id = pr.customer_id
           LEFT JOIN LATERAL (
             SELECT
               count(*) FILTER (
                 WHERE pm.status IN ('suggested', 'selected', 'hired')
               )::int AS shortlist_count,
               COALESCE(
                 jsonb_agg(pm.candidate_user_id::text ORDER BY pm.created_at)
                   FILTER (WHERE pm.status IN ('suggested', 'selected', 'hired')),
                 '[]'::jsonb
               ) AS shortlist_user_ids
             FROM public.placement_matches pm
             WHERE pm.placement_request_id = pr.id
           ) matches ON true
           ORDER BY pr.created_at DESC
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

  def list_admin_cleaner_applications(user_id) do
    admin_json_list(user_id, """
    SELECT jsonb_build_object(
      'id', ca.id,
      'userId', ca.user_id,
      'name', COALESCE(NULLIF(btrim(ca.name), ''), 'Applicant'),
      'email', ca.email,
      'phone', ca.phone,
      'status', COALESCE(NULLIF(btrim(ca.status), ''), 'pending'),
      'kycStatus', COALESCE(NULLIF(btrim(ca.kyc_status), ''), 'pending'),
      'hourlyRateGhs', ca.hourly_rate,
      'skills', COALESCE(to_jsonb(ca.skills), '[]'::jsonb),
      'createdAt', ca.created_at
    )
    FROM public.cleaner_applications ca
    ORDER BY ca.created_at DESC NULLS LAST
    LIMIT 200
    """)
  end

  def get_admin_cleaner_application(user_id, application_id) do
    admin_json_row(user_id, application_id, """
    SELECT jsonb_build_object(
      'id', ca.id,
      'userId', ca.user_id,
      'name', COALESCE(NULLIF(btrim(ca.name), ''), 'Applicant'),
      'email', ca.email,
      'phone', ca.phone,
      'status', COALESCE(NULLIF(btrim(ca.status), ''), 'pending'),
      'kycStatus', COALESCE(NULLIF(btrim(ca.kyc_status), ''), 'pending'),
      'hourlyRateGhs', ca.hourly_rate,
      'skills', COALESCE(to_jsonb(ca.skills), '[]'::jsonb),
      'createdAt', ca.created_at,
      'bio', NULLIF(btrim(ca.bio), ''),
      'applicantBio', NULLIF(btrim(ca.applicant_bio), ''),
      'languages', COALESCE(to_jsonb(ca.languages), '[]'::jsonb),
      'serviceAreas', COALESCE(to_jsonb(ca.service_areas), '[]'::jsonb),
      'yearsOfExperience', ca.years_of_experience,
      'hoursPerWeek', ca.hours_per_week,
      'certifications', COALESCE(to_jsonb(ca.certifications), '[]'::jsonb),
      'adminFeedback', NULLIF(btrim(ca.admin_feedback), '')
    )
    FROM public.cleaner_applications ca
    WHERE ca.id = $1
    LIMIT 1
    """)
  end

  def list_admin_cleaner_application_drafts(user_id) do
    admin_json_list(user_id, """
    SELECT jsonb_build_object(
      'id', d.id,
      'userId', d.user_id,
      'name', COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        NULLIF(btrim(concat_ws(' ', d.payload->>'firstName', d.payload->>'lastName')), ''),
        u.email,
        d.email,
        'Applicant'
      ),
      'email', COALESCE(NULLIF(btrim(d.email), ''), u.email),
      'phone', COALESCE(NULLIF(btrim(u.phone), ''), NULLIF(btrim(d.payload->>'phone'), '')),
      'currentStep', d.current_step,
      'createdAt', d.created_at,
      'updatedAt', d.updated_at,
      'lastSavedAt', d.last_saved_at
    )
    FROM public.cleaner_application_drafts d
    LEFT JOIN public.users u ON u.id = d.user_id
    LEFT JOIN public.profiles p ON p.id = d.user_id
    ORDER BY d.updated_at DESC
    LIMIT 200
    """)
  end

  def get_admin_cleaner_application_draft(user_id, draft_id) do
    admin_json_row(user_id, draft_id, """
    SELECT jsonb_build_object(
      'id', d.id,
      'userId', d.user_id,
      'name', COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        NULLIF(btrim(concat_ws(' ', d.payload->>'firstName', d.payload->>'lastName')), ''),
        u.email,
        d.email,
        'Applicant'
      ),
      'email', COALESCE(NULLIF(btrim(d.email), ''), u.email),
      'phone', COALESCE(NULLIF(btrim(u.phone), ''), NULLIF(btrim(d.payload->>'phone'), '')),
      'currentStep', d.current_step,
      'createdAt', d.created_at,
      'updatedAt', d.updated_at,
      'lastSavedAt', d.last_saved_at,
      'city', NULLIF(btrim(d.payload->>'city'), ''),
      'bio', NULLIF(btrim(d.payload->>'bio'), ''),
      'hoursPerWeek', NULLIF(btrim(d.payload->>'hoursPerWeek'), ''),
      'skills', CASE
        WHEN jsonb_typeof(d.payload->'skills') = 'array' THEN d.payload->'skills'
        ELSE '[]'::jsonb
      END,
      'workAreas', CASE
        WHEN jsonb_typeof(d.payload->'workAreas') = 'array' THEN d.payload->'workAreas'
        ELSE '[]'::jsonb
      END
    )
    FROM public.cleaner_application_drafts d
    LEFT JOIN public.users u ON u.id = d.user_id
    LEFT JOIN public.profiles p ON p.id = d.user_id
    WHERE d.id = $1
    LIMIT 1
    """)
  end

  def list_admin_cleaner_health(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, kpis} <- query_json_row(admin_cleaner_health_kpis_sql()),
         {:ok, cases} <- query_json_list(admin_cleaner_health_cases_sql()) do
      {:ok, %{kpis: kpis, cases: cases}}
    else
      :error -> {:error, :invalid_user}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def get_admin_cleaner_health_case(user_id, case_id) do
    admin_json_row(user_id, case_id, """
    SELECT jsonb_build_object(
      'id', c.id,
      'cleanerId', c.cleaner_id,
      'cleanerName', COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        'Unknown cleaner'
      ),
      'severity', c.severity,
      'riskScore', COALESCE(s.risk_score, 0),
      'riskLevel', s.risk_level,
      'mainReason', c.title,
      'rating', s.rating,
      'recentJobs', COALESCE(s.completed_jobs, 0),
      'assignedToName', CASE
        WHEN c.assigned_to IS NULL THEN NULL
        ELSE COALESCE(
          NULLIF(btrim(a.fullname), ''),
          NULLIF(btrim(concat_ws(' ', a.firstname, a.lastname)), ''),
          NULL
        )
      END,
      'status', c.status,
      'createdAt', c.created_at,
      'aiSummary', NULLIF(btrim(c.ai_summary), ''),
      'aiRecommendation', NULLIF(btrim(c.ai_recommendation), ''),
      'aiCategories', COALESCE(to_jsonb(c.ai_categories), '[]'::jsonb),
      'resolutionNotes', NULLIF(btrim(c.resolution_notes), ''),
      'evidenceJson', CASE
        WHEN c.evidence IS NULL OR c.evidence = '{}'::jsonb THEN NULL
        ELSE c.evidence::text
      END,
      'riskReasons', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'label', CASE
              WHEN jsonb_typeof(r) = 'object' THEN COALESCE(
                NULLIF(r->>'label', ''),
                NULLIF(r->>'code', ''),
                'Risk factor'
              )
              ELSE COALESCE(NULLIF(btrim(r#>>'{}'), ''), 'Risk factor')
            END,
            'points', CASE
              WHEN jsonb_typeof(r) = 'object' THEN COALESCE((r->>'points')::int, 0)
              ELSE 0
            END
          )
          ORDER BY ordinality
        )
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(s.risk_reasons) = 'array' AND jsonb_array_length(s.risk_reasons) > 0 THEN s.risk_reasons
            WHEN jsonb_typeof(c.evidence->'risk_reasons') = 'array' THEN c.evidence->'risk_reasons'
            ELSE '[]'::jsonb
          END
        ) WITH ORDINALITY AS t(r, ordinality)
      ), '[]'::jsonb),
      'reviewComments', COALESCE((
        SELECT jsonb_agg(btrim(elem#>>'{}') ORDER BY ordinality)
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(c.evidence->'review_comments') = 'array' THEN c.evidence->'review_comments'
            ELSE '[]'::jsonb
          END
        ) WITH ORDINALITY AS t(elem, ordinality)
        WHERE NULLIF(btrim(elem#>>'{}'), '') IS NOT NULL
      ), '[]'::jsonb),
      'actions', COALESCE((
        SELECT jsonb_agg(x ORDER BY ordinality)
        FROM (
          SELECT jsonb_build_object(
            'actionType', act.action_type,
            'notes', NULLIF(btrim(act.notes), ''),
            'createdAt', act.created_at
          ) AS x,
          row_number() OVER (ORDER BY act.created_at DESC) AS ordinality
          FROM public.cleaner_case_actions act
          WHERE act.case_id = c.id
          ORDER BY act.created_at DESC
          LIMIT 20
        ) history
      ), '[]'::jsonb),
      'previousCases', COALESCE((
        SELECT jsonb_agg(x ORDER BY ordinality)
        FROM (
          SELECT jsonb_build_object(
            'id', prev.id,
            'title', prev.title,
            'status', prev.status,
            'severity', prev.severity,
            'createdAt', prev.created_at
          ) AS x,
          row_number() OVER (ORDER BY prev.created_at DESC) AS ordinality
          FROM public.cleaner_operations_cases prev
          WHERE prev.cleaner_id = c.cleaner_id AND prev.id <> c.id
          ORDER BY prev.created_at DESC
          LIMIT 10
        ) earlier
      ), '[]'::jsonb)
    )
    FROM public.cleaner_operations_cases c
    LEFT JOIN public.cleaner_health_snapshots s ON s.id = c.snapshot_id
    LEFT JOIN public.profiles p ON p.id = c.cleaner_id
    LEFT JOIN public.profiles a ON a.id = c.assigned_to
    WHERE c.id = $1
    LIMIT 1
    """)
  end

  def list_admin_customer_trust(user_id) do
    admin_json_list(user_id, """
    SELECT jsonb_build_object(
      'customerId', t.customer_id,
      'name', COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        u.email,
        u.phone,
        'Customer'
      ),
      'email', u.email,
      'phone', u.phone,
      'verificationStage', t.verification_required_stage,
      'verificationRequired', t.verification_required,
      'idVerified', t.id_verified,
      'phoneVerified', t.phone_verified,
      'canProceedToPayment', t.verification_required_stage IS NULL OR t.verification_required_stage = 'before_dispatch',
      'canDispatchCleaner', t.verification_required_stage IS NULL,
      'riskScore', t.risk_score,
      'failedPaymentCount', t.failed_payment_count,
      'chargebackCount', t.chargeback_count,
      'cleanerComplaintCount', t.cleaner_complaint_count,
      'completedBookingsCount', t.completed_bookings_count,
      'lastRiskEventAt', t.last_risk_event_at
    )
    FROM public.customer_trust_profiles t
    LEFT JOIN public.users u ON u.id = t.customer_id
    LEFT JOIN public.profiles p ON p.id = t.customer_id
    ORDER BY t.last_risk_event_at DESC NULLS LAST, t.updated_at DESC
    LIMIT 200
    """)
  end

  def get_admin_customer_trust(user_id, customer_id) do
    admin_json_row(user_id, customer_id, """
    SELECT jsonb_build_object(
      'customerId', t.customer_id,
      'name', COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        u.email,
        u.phone,
        'Customer'
      ),
      'email', u.email,
      'phone', u.phone,
      'verificationStage', t.verification_required_stage,
      'verificationRequired', t.verification_required,
      'verificationReason', NULLIF(btrim(t.verification_required_reason), ''),
      'idVerified', t.id_verified,
      'phoneVerified', t.phone_verified,
      'canProceedToPayment', t.verification_required_stage IS NULL OR t.verification_required_stage = 'before_dispatch',
      'canDispatchCleaner', t.verification_required_stage IS NULL,
      'riskScore', t.risk_score,
      'failedPaymentCount', t.failed_payment_count,
      'chargebackCount', t.chargeback_count,
      'cleanerComplaintCount', t.cleaner_complaint_count,
      'completedBookingsCount', t.completed_bookings_count,
      'lastRiskEventAt', t.last_risk_event_at,
      'lastReviewedAt', t.last_reviewed_at,
      'adminOverrideStage', t.admin_override_stage,
      'adminOverrideReason', NULLIF(btrim(t.admin_override_reason), ''),
      'adminExplanation', CASE t.verification_required_stage
        WHEN 'before_payment' THEN
          'Blocked before payment: ' || COALESCE(NULLIF(btrim(t.verification_required_reason), ''), 'verification required')
          || ' (failed payments total=' || t.failed_payment_count::text
          || ', chargebacks=' || t.chargeback_count::text
          || ', complaints=' || t.cleaner_complaint_count::text || ').'
        WHEN 'before_dispatch' THEN
          'Allowed to pay but blocked before dispatch: ' || COALESCE(NULLIF(btrim(t.verification_required_reason), ''), 'verification required')
          || ' ID verified=' || t.id_verified::text
          || ', completed bookings=' || t.completed_bookings_count::text || '.'
        WHEN 'manual_review' THEN
          'Manual review: ' || COALESCE(NULLIF(btrim(t.verification_required_reason), ''), 'verification required')
          || ' (chargebacks=' || t.chargeback_count::text
          || ', complaints=' || t.cleaner_complaint_count::text || ').'
        ELSE 'Allowed because customer is not in manual review and payment/dispatch gates are clear.'
      END,
      'kycStatus', kyc.kyc_status,
      'kycReviewAnswer', kyc.review_answer,
      'kycUpdatedAt', kyc.updated_at,
      'riskEvents', COALESCE((
        SELECT jsonb_agg(x ORDER BY ordinality)
        FROM (
          SELECT jsonb_build_object(
            'eventType', e.event_type,
            'severity', e.severity,
            'createdAt', e.created_at,
            'voided', e.voided_at IS NOT NULL,
            'bookingId', e.booking_id
          ) AS x,
          row_number() OVER (ORDER BY e.created_at DESC) AS ordinality
          FROM public.customer_risk_events e
          WHERE e.customer_id = t.customer_id
          ORDER BY e.created_at DESC
          LIMIT 40
        ) events
      ), '[]'::jsonb),
      'bookings', COALESCE((
        SELECT jsonb_agg(x ORDER BY ordinality)
        FROM (
          SELECT jsonb_build_object(
            'id', b.id,
            'scheduledDate', b.scheduled_date,
            'scheduledTime', b.scheduled_time,
            'status', b.status,
            'paymentStatus', b.payment_status,
            'finalAmountMinor', b.final_amount_minor,
            'title', NULLIF(btrim(b.title), ''),
            'address', NULLIF(btrim(b.address), '')
          ) AS x,
          row_number() OVER (ORDER BY b.created_at DESC) AS ordinality
          FROM public.bookings b
          WHERE b.customer_id = t.customer_id
          ORDER BY b.created_at DESC
          LIMIT 20
        ) recent
      ), '[]'::jsonb),
      'adminNotes', COALESCE((
        SELECT jsonb_agg(x ORDER BY ordinality)
        FROM (
          SELECT jsonb_build_object(
            'note', n.note,
            'createdAt', n.created_at
          ) AS x,
          row_number() OVER (ORDER BY n.created_at DESC) AS ordinality
          FROM public.customer_risk_admin_notes n
          WHERE n.customer_id = t.customer_id
          ORDER BY n.created_at DESC
          LIMIT 50
        ) notes
      ), '[]'::jsonb),
      'adminActions', COALESCE((
        SELECT jsonb_agg(x ORDER BY ordinality)
        FROM (
          SELECT jsonb_build_object(
            'actionType', a.action_type,
            'reason', NULLIF(btrim(a.reason), ''),
            'createdAt', a.created_at
          ) AS x,
          row_number() OVER (ORDER BY a.created_at DESC) AS ordinality
          FROM public.customer_risk_admin_actions a
          WHERE a.customer_id = t.customer_id
          ORDER BY a.created_at DESC
          LIMIT 50
        ) history
      ), '[]'::jsonb)
    )
    FROM public.customer_trust_profiles t
    LEFT JOIN public.users u ON u.id = t.customer_id
    LEFT JOIN public.profiles p ON p.id = t.customer_id
    LEFT JOIN LATERAL (
      SELECT kp.kyc_status, kp.review_answer, kp.updated_at
      FROM public.kyc_profiles kp
      WHERE kp.user_id = t.customer_id
      ORDER BY kp.updated_at DESC NULLS LAST
      LIMIT 1
    ) kyc ON true
    WHERE t.customer_id = $1
    LIMIT 1
    """)
  end

  def record_admin_cleaner_health_action(user_id, case_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, cid} <- dump_uuid(case_id),
         :ok <- require_admin(uid),
         {:ok, action_type, notes, next_status} <- parse_health_action(params) do
      Repo.transaction(fn ->
        [_id, current_status] =
          one_row_or_rollback(
            """
            SELECT id, status
            FROM public.cleaner_operations_cases
            WHERE id = $1
            FOR UPDATE
            """,
            [cid],
            :not_found
          )

        status = next_status || current_status

        with_query_or_rollback(
          """
          INSERT INTO public.cleaner_case_actions (case_id, action_type, notes, created_by)
          VALUES ($1, $2, $3, $4)
          """,
          [cid, action_type, notes, uid]
        )

        with_query_or_rollback(
          """
          UPDATE public.cleaner_operations_cases
          SET
            status = $2,
            updated_at = now(),
            reviewed_by = CASE WHEN $2 IN ('resolved', 'dismissed') THEN $3 ELSE reviewed_by END,
            reviewed_at = CASE WHEN $2 IN ('resolved', 'dismissed') THEN now() ELSE reviewed_at END,
            resolution_notes = CASE WHEN $2 IN ('resolved', 'dismissed') THEN $4 ELSE resolution_notes END
          WHERE id = $1
          """,
          [cid, status, uid, notes]
        )

        %{message: "Action recorded"}
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def add_admin_customer_trust_note(user_id, customer_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, cid} <- dump_uuid(customer_id),
         :ok <- require_admin(uid),
         {:ok, note} <- required_text(params["note"], 4000) do
      Repo.transaction(fn ->
        one_row_or_rollback(
          """
          SELECT customer_id
          FROM public.customer_trust_profiles
          WHERE customer_id = $1
          FOR UPDATE
          """,
          [cid],
          :not_found
        )

        with_query_or_rollback(
          """
          INSERT INTO public.customer_risk_admin_notes (customer_id, admin_user_id, note)
          VALUES ($1, $2, $3)
          """,
          [cid, uid, note]
        )

        insert_trust_admin_action(cid, uid, "admin_note_added", note)
        %{message: "Note saved"}
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  def record_admin_customer_trust_action(user_id, customer_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, cid} <- dump_uuid(customer_id),
         :ok <- require_admin(uid),
         {:ok, action, reason} <- parse_trust_action(params) do
      Repo.transaction(fn ->
        one_row_or_rollback(
          """
          SELECT customer_id
          FROM public.customer_trust_profiles
          WHERE customer_id = $1
          FOR UPDATE
          """,
          [cid],
          :not_found
        )

        recalculate_trust_profile(cid)
        apply_trust_action(cid, uid, action, reason)
        %{message: "Action recorded"}
      end)
      |> normalize_transaction()
    else
      :error -> {:error, :invalid_request}
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

  defp admin_cleaner_health_kpis_sql do
    """
    SELECT jsonb_build_object(
      'openCases', (
        SELECT count(*)::int
        FROM public.cleaner_operations_cases
        WHERE status IN ('open', 'reviewing', 'monitoring')
      ),
      'redRiskCleaners', (
        SELECT count(*)::int
        FROM public.cleaner_health_snapshots
        WHERE snapshot_date = current_date AND risk_level = 'red'
      ),
      'yellowRiskCleaners', (
        SELECT count(*)::int
        FROM public.cleaner_health_snapshots
        WHERE snapshot_date = current_date AND risk_level = 'yellow'
      ),
      'averageCleanerRating', (
        SELECT round(avg(rating)::numeric, 1)::float
        FROM public.cleaner_data
        WHERE rating IS NOT NULL
      ),
      'noShowsThisMonth', (
        SELECT coalesce(sum(no_show_count), 0)::int
        FROM public.cleaner_health_snapshots
        WHERE snapshot_date >= date_trunc('month', current_date)::date
      ),
      'complaintsThisMonth', (
        SELECT coalesce(sum(complaint_count), 0)::int
        FROM public.cleaner_health_snapshots
        WHERE snapshot_date >= date_trunc('month', current_date)::date
      )
    )
    """
  end

  defp admin_cleaner_health_cases_sql do
    """
    SELECT jsonb_build_object(
      'id', c.id,
      'cleanerId', c.cleaner_id,
      'cleanerName', COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        'Unknown cleaner'
      ),
      'severity', c.severity,
      'riskScore', COALESCE(s.risk_score, 0),
      'mainReason', c.title,
      'rating', s.rating,
      'recentJobs', COALESCE(s.completed_jobs, 0),
      'assignedToName', CASE
        WHEN c.assigned_to IS NULL THEN NULL
        ELSE COALESCE(
          NULLIF(btrim(a.fullname), ''),
          NULLIF(btrim(concat_ws(' ', a.firstname, a.lastname)), ''),
          NULL
        )
      END,
      'status', c.status,
      'createdAt', c.created_at
    )
    FROM public.cleaner_operations_cases c
    LEFT JOIN public.cleaner_health_snapshots s ON s.id = c.snapshot_id
    LEFT JOIN public.profiles p ON p.id = c.cleaner_id
    LEFT JOIN public.profiles a ON a.id = c.assigned_to
    ORDER BY c.created_at DESC
    LIMIT 200
    """
  end

  defp query_json_list(sql) do
    case Repo.query(sql) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp query_json_row(sql) do
    case Repo.query(sql) do
      {:ok, %{rows: [[row]]}} -> {:ok, row}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp admin_json_list(user_id, sql) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, result} <- Repo.query(sql) do
      {:ok, Enum.map(result.rows, &hd/1)}
    else
      :error -> {:error, :invalid_user}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  defp admin_json_row(user_id, id, sql) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, rid} <- dump_uuid(id),
         :ok <- require_admin(uid),
         {:ok, result} <- Repo.query(sql, [rid]) do
      case result.rows do
        [[row]] -> {:ok, row}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, error} when is_atom(error) -> {:error, error}
      {:error, error} -> database_error(error)
    end
  end

  defp require_admin(uid) do
    case Repo.query(
           """
           SELECT EXISTS (
             SELECT 1
             FROM public.user_roles
             WHERE user_id = $1
               AND role_id IN ('admin', 'reviewer')
           )
           """,
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

  @health_actions ~w(monitor coaching training warning investigation resolved dismissed)
  @disciplinary_health_actions ~w(warning training investigation)
  @trust_actions ~w(
    mark_reviewed
    clear_manual_review
    require_manual_review
    require_id_before_payment
    require_id_before_dispatch
  )

  defp parse_health_action(params) do
    action = params["actionType"]
    notes = optional_text(params["notes"], 4000)

    cond do
      action not in @health_actions ->
        {:error, :invalid_request}

      notes == :error ->
        {:error, :invalid_request}

      true ->
        {db_action, next_status, stored_notes} =
          case action do
            "dismissed" -> {"note", "dismissed", notes || "Case dismissed"}
            "resolved" -> {"resolved", "resolved", notes || "Case resolved"}
            "monitor" -> {"monitor", "monitoring", notes}
            other when other in @disciplinary_health_actions -> {other, "reviewing", notes}
            other -> {other, nil, notes}
          end

        {:ok, db_action, stored_notes, next_status}
    end
  end

  defp parse_trust_action(params) do
    action = params["action"]

    with true <- action in @trust_actions,
         {:ok, reason} <- required_text(params["reason"], 2000) do
      {:ok, action, reason}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp optional_text(nil, _max), do: nil

  defp optional_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      byte_size(trimmed) > max -> :error
      true -> trimmed
    end
  end

  defp optional_text(_value, _max), do: :error

  defp required_text(value, max) do
    case optional_text(value, max) do
      :error -> {:error, :invalid_request}
      nil -> {:error, :invalid_request}
      text -> {:ok, text}
    end
  end

  defp recalculate_trust_profile(cid) do
    case Repo.query("SELECT public.recalculate_customer_trust_profile($1)", [cid]) do
      {:ok, _} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :undefined_function}}} -> :ok
      {:error, error} -> Repo.rollback({:database, error})
    end
  end

  defp apply_trust_action(cid, uid, "mark_reviewed", reason) do
    with_query_or_rollback(
      """
      UPDATE public.customer_trust_profiles
      SET last_reviewed_at = now(), updated_at = now()
      WHERE customer_id = $1
      """,
      [cid]
    )

    insert_trust_admin_action(cid, uid, "customer_risk_reviewed", reason)
  end

  defp apply_trust_action(cid, uid, "clear_manual_review", reason) do
    with_query_or_rollback(
      """
      UPDATE public.customer_trust_profiles
      SET
        manual_review_cleared_at = now(),
        admin_override_stage = NULL,
        admin_override_reason = $2,
        admin_override_set_at = now(),
        admin_override_set_by = $3,
        updated_at = now()
      WHERE customer_id = $1
      """,
      [cid, reason, uid]
    )

    insert_trust_admin_action(cid, uid, "manual_review_cleared", reason)
  end

  defp apply_trust_action(cid, uid, "require_manual_review", reason) do
    with_query_or_rollback(
      """
      UPDATE public.customer_trust_profiles
      SET
        admin_override_stage = 'manual_review',
        admin_override_reason = $2,
        admin_override_set_at = now(),
        admin_override_set_by = $3,
        manual_review_cleared_at = NULL,
        updated_at = now()
      WHERE customer_id = $1
      """,
      [cid, reason, uid]
    )

    insert_trust_admin_action(cid, uid, "manual_review_required", reason)
  end

  defp apply_trust_action(cid, uid, "require_id_before_payment", reason) do
    with_query_or_rollback(
      """
      UPDATE public.customer_trust_profiles
      SET
        admin_override_stage = 'before_payment',
        admin_override_reason = $2,
        admin_override_set_at = now(),
        admin_override_set_by = $3,
        updated_at = now()
      WHERE customer_id = $1
      """,
      [cid, reason, uid]
    )

    insert_trust_admin_action(cid, uid, "id_verification_required", reason)
  end

  defp apply_trust_action(cid, uid, "require_id_before_dispatch", reason) do
    with_query_or_rollback(
      """
      UPDATE public.customer_trust_profiles
      SET
        admin_override_stage = 'before_dispatch',
        admin_override_reason = $2,
        admin_override_set_at = now(),
        admin_override_set_by = $3,
        updated_at = now()
      WHERE customer_id = $1
      """,
      [cid, reason, uid]
    )

    insert_trust_admin_action(cid, uid, "id_verification_required", reason)
  end

  defp insert_trust_admin_action(cid, uid, action_type, reason) do
    with_query_or_rollback(
      """
      INSERT INTO public.customer_risk_admin_actions (
        customer_id,
        admin_user_id,
        action_type,
        reason,
        metadata
      ) VALUES ($1, $2, $3, $4, '{}'::jsonb)
      """,
      [cid, uid, action_type, reason]
    )
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_value), do: :error

  defp database_error(error) do
    Logger.error("Direct database operation failed: #{Exception.message(error)}")
    {:error, :database_unavailable}
  end
end
