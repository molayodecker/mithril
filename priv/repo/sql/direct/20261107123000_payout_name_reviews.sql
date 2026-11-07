-- Pending payout name reviews, and keep that hold when no payout method exists yet.
-- Replayable. The reconcile function already exists; this replaces only the
-- no-method branch so a pending Direct review is not cleared as no_methods.

CREATE TABLE IF NOT EXISTS public.payout_name_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  purpose text NOT NULL CHECK (purpose IN ('payout', 'refund')),
  payout_type text NOT NULL CHECK (payout_type IN ('bank', 'mobile_money')),
  profile_name text,
  account_name text,
  submitted_name text,
  names_match boolean NOT NULL,
  status text NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
  bank_code text,
  account_number text NOT NULL,
  review_notes text,
  reviewed_by uuid REFERENCES public.users(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payout_name_reviews_status_created_idx
  ON public.payout_name_reviews (status, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS payout_name_reviews_one_pending_idx
  ON public.payout_name_reviews (user_id, purpose, account_number)
  WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.reconcile_payout_name_mismatch_flag(
  p_user_id uuid,
  p_purpose text DEFAULT 'payout'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_purpose text := lower(btrim(coalesce(p_purpose, 'payout')));
  v_profile public.profiles%ROWTYPE;
  v_prefs jsonb;
  v_flag jsonb;
  v_flag_source text; -- 'nested' | 'legacy' | 'both_same'
  v_nested jsonb;
  v_legacy jsonb;
  v_flagged_at text;
  v_stored_profile text;
  v_stored_payout text;
  v_payout_type text;
  v_current_profile text;
  v_method_count integer := 0;
  v_blank_count integer := 0;
  v_flagged_name_present boolean := false;
  v_all_match_profile boolean := false;
  v_should_clear boolean := false;
  v_clear_reason text := NULL;
  v_cleared_id uuid;
  v_active jsonb;
  v_next_prefs jsonb;
  v_next_nested jsonb;
  v_clear_legacy boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  IF p_user_id IS NULL OR v_uid IS DISTINCT FROM p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authorized');
  END IF;

  IF v_purpose NOT IN ('payout', 'refund') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_purpose');
  END IF;

  -- Lock order: advisory user lock, then profile row (matches trigger lock order).
  PERFORM public._acquire_payout_methods_user_lock(p_user_id);

  SELECT *
  INTO v_profile
  FROM public.profiles p
  WHERE p.id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'profile_not_found');
  END IF;

  v_prefs := coalesce(v_profile.preferences, '{}'::jsonb);
  v_nested := v_prefs -> 'payout_name_mismatches' -> v_purpose;
  IF v_purpose = 'payout'
     AND v_prefs -> 'payout_name_mismatch' IS NOT NULL
     AND jsonb_typeof(v_prefs -> 'payout_name_mismatch') = 'object' THEN
    v_legacy := v_prefs -> 'payout_name_mismatch';
  ELSE
    v_legacy := NULL;
  END IF;

  IF v_nested IS NOT NULL AND jsonb_typeof(v_nested) = 'object' AND v_legacy IS NOT NULL THEN
    -- Dual-write / rollout: never clear both unless they are the same mismatch event.
    IF NOT public._payout_mismatch_flags_same_event(v_nested, v_legacy) THEN
      RETURN jsonb_build_object(
        'success', true,
        'cleared', false,
        'clear_confirmed', false,
        'reason', 'conflicting_flags',
        'purpose', v_purpose,
        'active', jsonb_build_object(
          'profile_name', nullif(btrim(coalesce(v_nested ->> 'profile_name', '')), ''),
          'payout_account_name', nullif(btrim(coalesce(v_nested ->> 'payout_account_name', '')), ''),
          'payout_type', coalesce(nullif(btrim(coalesce(v_nested ->> 'payout_type', '')), ''), 'bank'),
          'flagged_at', nullif(btrim(coalesce(v_nested ->> 'flagged_at', '')), ''),
          'purpose', v_purpose,
          'legacy_flagged_at', nullif(btrim(coalesce(v_legacy ->> 'flagged_at', '')), '')
        )
      );
    END IF;
    v_flag := v_nested;
    v_flag_source := 'both_same';
    v_clear_legacy := true;
  ELSIF v_nested IS NOT NULL AND jsonb_typeof(v_nested) = 'object' THEN
    v_flag := v_nested;
    v_flag_source := 'nested';
    v_clear_legacy := false;
  ELSIF v_legacy IS NOT NULL THEN
    -- Legacy single-flag shape defaults to purpose=payout.
    v_flag := v_legacy;
    v_flag_source := 'legacy';
    v_clear_legacy := true;
  ELSE
    RETURN jsonb_build_object(
      'success', true,
      'cleared', false,
      'clear_confirmed', false,
      'reason', 'no_flag',
      'purpose', v_purpose,
      'active', NULL
    );
  END IF;

  v_flagged_at := nullif(btrim(coalesce(v_flag ->> 'flagged_at', '')), '');
  v_stored_profile := nullif(btrim(coalesce(v_flag ->> 'profile_name', '')), '');
  v_stored_payout := nullif(btrim(coalesce(v_flag ->> 'payout_account_name', '')), '');
  v_payout_type := nullif(btrim(coalesce(v_flag ->> 'payout_type', '')), '');

  IF v_stored_profile IS NULL OR v_stored_payout IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'cleared', false,
      'clear_confirmed', false,
      'reason', 'incomplete_flag',
      'purpose', v_purpose,
      'active', NULL
    );
  END IF;

  v_active := jsonb_build_object(
    'profile_name', v_stored_profile,
    'payout_account_name', v_stored_payout,
    'payout_type', coalesce(v_payout_type, 'bank'),
    'flagged_at', v_flagged_at,
    'purpose', v_purpose
  );

  -- Stored names already match under the mobile comparator (case/order/typos).
  IF public._payout_names_match(v_stored_profile, v_stored_payout) THEN
    v_should_clear := true;
    v_clear_reason := 'case_only';
  ELSE
    v_current_profile := nullif(
      btrim(
        coalesce(
          nullif(btrim(coalesce(v_profile.fullname, '')), ''),
          nullif(
            btrim(
              concat_ws(
                ' ',
                nullif(btrim(coalesce(v_profile.firstname, '')), ''),
                nullif(btrim(coalesce(v_profile.middlename, '')), ''),
                nullif(btrim(coalesce(v_profile.lastname, '')), '')
              )
            ),
            ''
          )
        )
      ),
      ''
    );

    SELECT
      count(*)::integer,
      count(*) FILTER (
        WHERE nullif(btrim(coalesce(pm.account_name, '')), '') IS NULL
      )::integer,
      bool_or(
        nullif(btrim(coalesce(pm.account_name, '')), '') IS NOT NULL
        AND public._payout_names_match(pm.account_name, v_stored_payout)
      ),
      bool_and(
        nullif(btrim(coalesce(pm.account_name, '')), '') IS NOT NULL
        AND public._payout_names_match(v_current_profile, pm.account_name)
      )
    INTO
      v_method_count,
      v_blank_count,
      v_flagged_name_present,
      v_all_match_profile
    FROM public.payout_methods pm
    WHERE pm.user_id = p_user_id
      AND coalesce(pm.purpose, 'payout') = v_purpose;

    -- Pause point for two-session concurrency tests (no-op unless GUC is set).
    PERFORM public._reconcile_payout_test_pause_if_configured();

    IF v_method_count = 0 THEN
      -- A pending Direct review has no payout method yet. Keep the hold.
      IF EXISTS (
        SELECT 1
        FROM public.payout_name_reviews review
        WHERE review.user_id = p_user_id
          AND review.purpose = v_purpose
          AND review.status = 'pending'
          AND review.names_match = false
      ) THEN
        v_should_clear := false;
        v_clear_reason := 'pending_name_review';
      ELSE
        v_should_clear := true;
        v_clear_reason := 'no_methods';
      END IF;
    ELSIF v_blank_count > 0 THEN
      v_should_clear := false;
      v_clear_reason := 'blank_method_names';
    ELSIF v_flagged_name_present THEN
      v_should_clear := false;
      v_clear_reason := 'flagged_name_present';
    ELSIF nullif(public._normalize_payout_name_compare(v_current_profile), '') IS NOT NULL
          AND coalesce(v_all_match_profile, false) THEN
      v_should_clear := true;
      v_clear_reason := 'methods_corrected';
    ELSE
      v_should_clear := false;
      v_clear_reason := 'still_mismatched';
    END IF;
  END IF;

  IF NOT v_should_clear THEN
    RETURN jsonb_build_object(
      'success', true,
      'cleared', false,
      'clear_confirmed', false,
      'reason', v_clear_reason,
      'purpose', v_purpose,
      'active', v_active
    );
  END IF;

  v_next_prefs := v_prefs;
  IF v_flag_source IN ('nested', 'both_same')
     OR (v_prefs -> 'payout_name_mismatches') IS NOT NULL THEN
    v_next_nested := coalesce(v_next_prefs -> 'payout_name_mismatches', '{}'::jsonb) - v_purpose;
    IF v_next_nested = '{}'::jsonb THEN
      v_next_prefs := v_next_prefs - 'payout_name_mismatches';
    ELSE
      v_next_prefs := jsonb_set(v_next_prefs, '{payout_name_mismatches}', v_next_nested, true);
    END IF;
  END IF;
  -- Only drop legacy when it is the source, or dual-write same-event companion.
  IF v_clear_legacy THEN
    v_next_prefs := v_next_prefs - 'payout_name_mismatch';
  END IF;

  UPDATE public.profiles p
  SET
    preferences = v_next_prefs,
    updated_at = now()
  WHERE p.id = p_user_id
    AND (
      v_flagged_at IS NULL
      OR (
        v_flag_source = 'legacy'
        AND p.preferences #>> '{payout_name_mismatch,flagged_at}' = v_flagged_at
      )
      OR (
        v_flag_source IN ('nested', 'both_same')
        AND p.preferences #>> array['payout_name_mismatches', v_purpose, 'flagged_at'] = v_flagged_at
        AND (
          v_flag_source = 'nested'
          OR p.preferences #>> '{payout_name_mismatch,flagged_at}' = v_flagged_at
        )
      )
    )
  RETURNING p.id INTO v_cleared_id;

  IF v_cleared_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'cleared', false,
      'clear_confirmed', false,
      'reason', 'concurrent_flag_changed',
      'purpose', v_purpose,
      'active', coalesce(
        (
          SELECT jsonb_build_object(
            'profile_name', nullif(btrim(coalesce(
              p.preferences #>> array['payout_name_mismatches', v_purpose, 'profile_name'],
              p.preferences #>> '{payout_name_mismatch,profile_name}'
            )), ''),
            'payout_account_name', nullif(btrim(coalesce(
              p.preferences #>> array['payout_name_mismatches', v_purpose, 'payout_account_name'],
              p.preferences #>> '{payout_name_mismatch,payout_account_name}'
            )), ''),
            'payout_type', coalesce(nullif(btrim(coalesce(
              p.preferences #>> array['payout_name_mismatches', v_purpose, 'payout_type'],
              p.preferences #>> '{payout_name_mismatch,payout_type}'
            )), ''), 'bank'),
            'flagged_at', nullif(btrim(coalesce(
              p.preferences #>> array['payout_name_mismatches', v_purpose, 'flagged_at'],
              p.preferences #>> '{payout_name_mismatch,flagged_at}'
            )), ''),
            'purpose', v_purpose
          )
          FROM public.profiles p
          WHERE p.id = p_user_id
            AND (
              (p.preferences -> 'payout_name_mismatches' -> v_purpose) IS NOT NULL
              OR (v_purpose = 'payout' AND p.preferences ? 'payout_name_mismatch')
            )
        ),
        v_active
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'cleared', true,
    'clear_confirmed', true,
    'reason', v_clear_reason,
    'purpose', v_purpose,
    'active', NULL
  );
END;
$$;

DO $$
BEGIN
  REVOKE ALL ON FUNCTION public.reconcile_payout_name_mismatch_flag(uuid, text) FROM PUBLIC;
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
  REVOKE ALL ON FUNCTION public.reconcile_payout_name_mismatch_flag(uuid, text) FROM anon;
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
  GRANT EXECUTE ON FUNCTION public.reconcile_payout_name_mismatch_flag(uuid, text) TO authenticated;
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
  GRANT EXECUTE ON FUNCTION public.reconcile_payout_name_mismatch_flag(uuid, text) TO service_role;
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END $$;

COMMENT ON FUNCTION public.reconcile_payout_name_mismatch_flag(uuid, text) IS
  'Advisory-lock + profile-lock reconcile of purpose-scoped payout name-mismatch flags.';
