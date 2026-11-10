-- The phone flags a payout-name mismatch on profiles.preferences. The Direct
-- queue only reads payout_name_reviews, which used to be created when Paystack
-- rejected the recipient name. Open a pending review from the profile flag too.
-- Safe to run again.

CREATE OR REPLACE FUNCTION public.enqueue_payout_name_review_from_flag(
  p_user_id uuid,
  p_preferences jsonb,
  p_purpose text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purpose text := lower(btrim(coalesce(p_purpose, 'payout')));
  v_flag jsonb;
  v_profile text;
  v_account text;
  v_type text;
BEGIN
  IF p_user_id IS NULL OR v_purpose NOT IN ('payout', 'refund') THEN
    RETURN;
  END IF;

  v_flag := p_preferences -> 'payout_name_mismatches' -> v_purpose;
  IF v_purpose = 'payout'
     AND (v_flag IS NULL OR jsonb_typeof(v_flag) IS DISTINCT FROM 'object') THEN
    v_flag := p_preferences -> 'payout_name_mismatch';
  END IF;

  IF v_flag IS NULL OR jsonb_typeof(v_flag) IS DISTINCT FROM 'object' THEN
    RETURN;
  END IF;

  v_profile := nullif(btrim(coalesce(v_flag ->> 'profile_name', '')), '');
  v_account := nullif(btrim(coalesce(v_flag ->> 'payout_account_name', '')), '');
  IF v_profile IS NULL OR v_account IS NULL THEN
    RETURN;
  END IF;

  -- Match the payout reconciliation semantics (reordered names, accents, typos).
  IF public._payout_names_match(v_profile, v_account) THEN
    RETURN;
  END IF;

  v_type := lower(btrim(coalesce(v_flag ->> 'payout_type', 'mobile_money')));
  IF v_type NOT IN ('bank', 'mobile_money') THEN
    v_type := 'mobile_money';
  END IF;

  -- Profile flags may be synced from an existing Direct review with a real
  -- account number. Do not manufacture an accountless duplicate, or replay a
  -- previously approved/rejected event during a rerun of this backfill.
  IF EXISTS (
    SELECT 1 FROM public.payout_name_reviews r
    WHERE r.user_id = p_user_id
      AND r.purpose = v_purpose
      AND r.payout_type = v_type
      AND lower(btrim(coalesce(r.account_name, ''))) = lower(btrim(v_account))
      AND r.status IN ('pending', 'approved', 'rejected')
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.payout_name_reviews (
    user_id, purpose, payout_type, profile_name, account_name, submitted_name,
    names_match, status, account_number
  ) VALUES (
    p_user_id, v_purpose, v_type, v_profile, v_account, v_account,
    false, 'pending', ''
  )
  ON CONFLICT (user_id, purpose, account_number) WHERE status = 'pending'
  DO UPDATE SET
    payout_type = EXCLUDED.payout_type,
    profile_name = EXCLUDED.profile_name,
    account_name = EXCLUDED.account_name,
    submitted_name = EXCLUDED.submitted_name,
    names_match = EXCLUDED.names_match,
    updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_payout_name_reviews_from_preferences()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('mithril.payout_name_review_sync', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  BEGIN
    IF TG_OP = 'INSERT'
       OR coalesce(NEW.preferences -> 'payout_name_mismatches' -> 'payout',
                   NEW.preferences -> 'payout_name_mismatch')
          IS DISTINCT FROM
          coalesce(OLD.preferences -> 'payout_name_mismatches' -> 'payout',
                   OLD.preferences -> 'payout_name_mismatch') THEN
      PERFORM public.enqueue_payout_name_review_from_flag(NEW.id, NEW.preferences, 'payout');
    END IF;

    IF TG_OP = 'INSERT'
       OR NEW.preferences -> 'payout_name_mismatches' -> 'refund'
          IS DISTINCT FROM
          OLD.preferences -> 'payout_name_mismatches' -> 'refund' THEN
      PERFORM public.enqueue_payout_name_review_from_flag(NEW.id, NEW.preferences, 'refund');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'payout name review enqueue failed for %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_payout_name_reviews ON public.profiles;
CREATE TRIGGER trg_enqueue_payout_name_reviews
AFTER INSERT OR UPDATE OF preferences ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_payout_name_reviews_from_preferences();

DO $$
DECLARE
  target_user uuid;
  target_preferences jsonb;
BEGIN
  FOR target_user, target_preferences IN
    SELECT p.id, p.preferences
    FROM public.profiles p
    WHERE p.preferences ? 'payout_name_mismatch'
       OR p.preferences ? 'payout_name_mismatches'
  LOOP
    PERFORM public.enqueue_payout_name_review_from_flag(target_user, target_preferences, 'payout');
    PERFORM public.enqueue_payout_name_review_from_flag(target_user, target_preferences, 'refund');
  END LOOP;
END $$;

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.enqueue_payout_name_review_from_flag(uuid, jsonb, text) FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.enqueue_payout_name_reviews_from_preferences() FROM PUBLIC';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping payout name review enqueue grants: %', SQLERRM;
END $$;
