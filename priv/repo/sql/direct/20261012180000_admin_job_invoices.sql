-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- Job invoices are created by operations and sent by Instaclean.
-- Line totals, the subtotal, and the amount due are computed here in pesewas.

CREATE SEQUENCE IF NOT EXISTS public.job_invoice_no_seq AS integer;

CREATE TABLE IF NOT EXISTS public.job_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL UNIQUE REFERENCES public.bookings(id) ON DELETE CASCADE,
  public_token text NOT NULL UNIQUE,
  invoice_no text NOT NULL,
  issued_on date NOT NULL,
  bill_to_name text NOT NULL,
  bill_to_address text,
  bill_to_phone text,
  bill_to_email text,
  project text NOT NULL,
  lines jsonb NOT NULL,
  adjustment_minor integer NOT NULL DEFAULT 0,
  subtotal_minor integer NOT NULL CHECK (subtotal_minor >= 0),
  total_minor integer NOT NULL,
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  notes text,
  signatory_role text,
  created_by uuid NOT NULL REFERENCES public.users(id),
  updated_by uuid REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_whatsapp_sent_at timestamptz,
  last_email_sent_at timestamptz
);

CREATE OR REPLACE FUNCTION public.upsert_admin_job_invoice(
  p_booking_id uuid,
  p_recorded_by uuid,
  p_invoice jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_line jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_description text;
  v_qty integer;
  v_days integer;
  v_unit integer;
  v_qty_text text;
  v_days_text text;
  v_unit_text text;
  v_product bigint;
  v_line_total integer;
  v_subtotal bigint := 0;
  v_adjustment integer;
  v_adjustment_text text;
  v_total bigint;
  v_invoice_no text;
  v_existing_no text;
  v_old_name text;
  v_old_address text;
  v_old_phone text;
  v_old_email text;
  v_token text;
  v_issued_on date;
  v_issued_text text;
  v_name text;
  v_address text;
  v_phone text;
  v_email text;
  v_project text;
  v_notes text;
  v_signatory text;
  v_row public.job_invoices%ROWTYPE;
BEGIN
  IF p_booking_id IS NULL OR p_recorded_by IS NULL OR p_invoice IS NULL THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;

  -- Fly MPG refuses REVOKE FROM PUBLIC. SECURITY DEFINER still runs as the owner,
  -- so only that connected role may call this. A reader/writer cannot escalate by
  -- setting mithril.actor_id.
  IF session_user IS DISTINCT FROM current_user THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  -- mithril.actor_id is set for this transaction from the authenticated session.
  -- A caller-supplied admin UUID is not enough to create or overwrite an invoice.
  IF current_setting('mithril.actor_id', true) IS DISTINCT FROM p_recorded_by::text THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF NOT public.admin_cash_payout_recorder_is_allowed(p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.bookings b WHERE b.id = p_booking_id) THEN
    RAISE EXCEPTION 'booking_not_found';
  END IF;

  IF jsonb_typeof(p_invoice -> 'lines') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_invoice -> 'lines') < 1
     OR jsonb_array_length(p_invoice -> 'lines') > 20 THEN
    RAISE EXCEPTION 'invalid_lines';
  END IF;

  FOR v_line IN SELECT jsonb_array_elements(p_invoice -> 'lines')
  LOOP
    v_description := trim(COALESCE(v_line ->> 'description', ''));
    IF v_description = '' OR length(v_description) > 200 THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;

    v_qty_text := v_line ->> 'qty';
    v_days_text := v_line ->> 'days';
    v_unit_text := v_line ->> 'unitMinor';

    IF v_unit_text IS NULL OR v_unit_text !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;
    v_unit := v_unit_text::integer;
    IF v_unit <= 0 THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;

    IF (v_qty_text IS NULL) <> (v_days_text IS NULL) THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;

    IF v_qty_text IS NULL THEN
      v_qty := NULL;
      v_days := NULL;
      v_line_total := v_unit;
    ELSE
      IF v_qty_text !~ '^[0-9]+$' OR v_days_text !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'invalid_lines';
      END IF;
      v_qty := v_qty_text::integer;
      v_days := v_days_text::integer;
      IF v_qty <= 0 OR v_qty > 10000 OR v_days <= 0 OR v_days > 10000 THEN
        RAISE EXCEPTION 'invalid_lines';
      END IF;
      v_product := v_qty::bigint * v_days::bigint * v_unit::bigint;
      IF v_product > 2147483647 THEN
        RAISE EXCEPTION 'amount_too_large';
      END IF;
      v_line_total := v_product::integer;
    END IF;

    v_subtotal := v_subtotal + v_line_total;
    IF v_subtotal > 2147483647 THEN
      RAISE EXCEPTION 'amount_too_large';
    END IF;

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'description', v_description,
      'qty', v_qty,
      'days', v_days,
      'unitMinor', v_unit,
      'totalMinor', v_line_total
    ));
  END LOOP;

  v_adjustment_text := p_invoice ->> 'adjustmentMinor';
  IF v_adjustment_text IS NULL OR v_adjustment_text !~ '^-?[0-9]+$' THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;
  v_adjustment := v_adjustment_text::integer;
  v_total := v_subtotal + v_adjustment::bigint;
  IF v_total > 2147483647 OR v_total < -2147483648 THEN
    RAISE EXCEPTION 'amount_too_large';
  END IF;

  v_issued_text := p_invoice ->> 'issuedOn';
  IF v_issued_text IS NULL OR v_issued_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;
  v_issued_on := v_issued_text::date;

  v_name := trim(COALESCE(p_invoice ->> 'billToName', ''));
  v_project := trim(COALESCE(p_invoice ->> 'project', ''));
  v_address := NULLIF(trim(COALESCE(p_invoice ->> 'billToAddress', '')), '');
  v_phone := NULLIF(trim(COALESCE(p_invoice ->> 'billToPhone', '')), '');
  v_email := NULLIF(lower(trim(COALESCE(p_invoice ->> 'billToEmail', ''))), '');
  v_notes := NULLIF(trim(COALESCE(p_invoice ->> 'notes', '')), '');
  v_signatory := NULLIF(trim(COALESCE(p_invoice ->> 'signatoryRole', '')), '');
  IF v_name = '' OR length(v_name) > 160
     OR v_project = '' OR length(v_project) > 160
     OR (v_address IS NOT NULL AND length(v_address) > 500)
     OR (v_phone IS NOT NULL AND length(v_phone) > 32)
     OR (v_email IS NOT NULL AND length(v_email) > 200)
     OR (v_notes IS NOT NULL AND length(v_notes) > 2000)
     OR (v_signatory IS NOT NULL AND length(v_signatory) > 80) THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;

  IF v_email IS NOT NULL AND v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  SELECT invoice_no, public_token, bill_to_name, bill_to_address, bill_to_phone, bill_to_email
  INTO v_existing_no, v_token, v_old_name, v_old_address, v_old_phone, v_old_email
  FROM public.job_invoices
  WHERE booking_id = p_booking_id
  FOR UPDATE;

  v_invoice_no := NULLIF(trim(COALESCE(p_invoice ->> 'invoiceNo', '')), '');
  IF v_invoice_no IS NOT NULL AND length(v_invoice_no) > 40 THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;
  IF v_invoice_no IS NULL THEN
    v_invoice_no := COALESCE(v_existing_no, nextval('public.job_invoice_no_seq')::text);
  END IF;

  IF v_token IS NULL OR v_old_name IS DISTINCT FROM v_name
     OR v_old_address IS DISTINCT FROM v_address
     OR v_old_phone IS DISTINCT FROM v_phone
     OR v_old_email IS DISTINCT FROM v_email THEN
    v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  END IF;

  INSERT INTO public.job_invoices (
    booking_id,
    public_token,
    invoice_no,
    issued_on,
    bill_to_name,
    bill_to_address,
    bill_to_phone,
    bill_to_email,
    project,
    lines,
    adjustment_minor,
    subtotal_minor,
    total_minor,
    currency,
    notes,
    signatory_role,
    created_by,
    updated_by
  )
  VALUES (
    p_booking_id,
    v_token,
    v_invoice_no,
    v_issued_on,
    v_name,
    v_address,
    v_phone,
    v_email,
    v_project,
    v_lines,
    v_adjustment,
    v_subtotal::integer,
    v_total::integer,
    'GHS',
    v_notes,
    v_signatory,
    p_recorded_by,
    p_recorded_by
  )
  ON CONFLICT (booking_id) DO UPDATE SET
    invoice_no = EXCLUDED.invoice_no,
    public_token = EXCLUDED.public_token,
    issued_on = EXCLUDED.issued_on,
    bill_to_name = EXCLUDED.bill_to_name,
    bill_to_address = EXCLUDED.bill_to_address,
    bill_to_phone = EXCLUDED.bill_to_phone,
    bill_to_email = EXCLUDED.bill_to_email,
    project = EXCLUDED.project,
    lines = EXCLUDED.lines,
    adjustment_minor = EXCLUDED.adjustment_minor,
    subtotal_minor = EXCLUDED.subtotal_minor,
    total_minor = EXCLUDED.total_minor,
    notes = EXCLUDED.notes,
    signatory_role = EXCLUDED.signatory_role,
    updated_by = EXCLUDED.updated_by,
    updated_at = now()
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'bookingId', v_row.booking_id,
    'publicToken', v_row.public_token,
    'invoiceNo', v_row.invoice_no,
    'issuedOn', to_char(v_row.issued_on, 'YYYY-MM-DD'),
    'billToName', v_row.bill_to_name,
    'billToAddress', v_row.bill_to_address,
    'billToPhone', v_row.bill_to_phone,
    'billToEmail', v_row.bill_to_email,
    'project', v_row.project,
    'lines', v_row.lines,
    'adjustmentMinor', v_row.adjustment_minor,
    'subtotalMinor', v_row.subtotal_minor,
    'totalMinor', v_row.total_minor,
    'currency', v_row.currency,
    'notes', v_row.notes,
    'signatoryRole', v_row.signatory_role,
    'lastWhatsappSentAt', v_row.last_whatsapp_sent_at,
    'lastEmailSentAt', v_row.last_email_sent_at
  );
END;
$function$;

COMMENT ON FUNCTION public.upsert_admin_job_invoice(uuid, uuid, jsonb) IS
  'Create or replace the invoice for one booking. Quantity times days times unit price, in pesewas. A blank quantity and days bills the unit price once.';
