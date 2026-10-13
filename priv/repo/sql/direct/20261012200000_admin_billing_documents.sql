-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- Custom invoices and payment advice are typed by operations and stored here.
-- Totals are computed in pesewas. form_type is w8ben or 1099.

CREATE SEQUENCE IF NOT EXISTS public.job_invoice_no_seq AS integer;
CREATE SEQUENCE IF NOT EXISTS public.payment_advice_no_seq AS integer;

CREATE TABLE IF NOT EXISTS public.admin_billing_invoices (
  id uuid PRIMARY KEY,
  form_type text NOT NULL CHECK (form_type IN ('w8ben', '1099')),
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
  created_by uuid NOT NULL REFERENCES public.users(id),
  updated_by uuid REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_billing_invoices_updated_idx
  ON public.admin_billing_invoices (updated_at DESC);

CREATE TABLE IF NOT EXISTS public.admin_payment_advices (
  id uuid PRIMARY KEY,
  form_type text NOT NULL CHECK (form_type IN ('w8ben', '1099')),
  advice_no text NOT NULL,
  pay_period text NOT NULL,
  payment_date date NOT NULL,
  paid_to_name text NOT NULL,
  paid_to_address text,
  paid_to_email text,
  paid_to_phone text,
  employee_id text,
  role_name text,
  department text,
  pay_type text,
  earnings jsonb NOT NULL,
  reimbursements jsonb NOT NULL,
  deductions jsonb NOT NULL,
  earnings_minor integer NOT NULL CHECK (earnings_minor >= 0),
  reimbursements_minor integer NOT NULL CHECK (reimbursements_minor >= 0),
  deductions_minor integer NOT NULL CHECK (deductions_minor >= 0),
  net_minor integer NOT NULL,
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  pay_method text,
  pay_account text,
  pay_network text,
  pay_reference text,
  created_by uuid NOT NULL REFERENCES public.users(id),
  updated_by uuid REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_payment_advices_updated_idx
  ON public.admin_payment_advices (updated_at DESC);

CREATE OR REPLACE FUNCTION public.upsert_admin_billing_invoice(
  p_invoice_id uuid,
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
  v_form text;
  v_issued_on date;
  v_issued_text text;
  v_name text;
  v_address text;
  v_phone text;
  v_email text;
  v_project text;
  v_notes text;
  v_row public.admin_billing_invoices%ROWTYPE;
BEGIN
  IF p_invoice_id IS NULL OR p_recorded_by IS NULL OR p_invoice IS NULL THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;

  IF NOT public.admin_cash_payout_recorder_is_allowed(p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  v_form := p_invoice ->> 'formType';
  IF v_form IS DISTINCT FROM 'w8ben' AND v_form IS DISTINCT FROM '1099' THEN
    RAISE EXCEPTION 'invalid_form_type';
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
  IF v_name = '' OR length(v_name) > 160
     OR v_project = '' OR length(v_project) > 160
     OR (v_address IS NOT NULL AND length(v_address) > 500)
     OR (v_phone IS NOT NULL AND length(v_phone) > 32)
     OR (v_email IS NOT NULL AND length(v_email) > 200)
     OR (v_notes IS NOT NULL AND length(v_notes) > 2000) THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;

  IF v_email IS NOT NULL AND v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  SELECT invoice_no INTO v_existing_no
  FROM public.admin_billing_invoices
  WHERE id = p_invoice_id
  FOR UPDATE;

  v_invoice_no := NULLIF(trim(COALESCE(p_invoice ->> 'invoiceNo', '')), '');
  IF v_invoice_no IS NOT NULL AND length(v_invoice_no) > 40 THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;
  IF v_invoice_no IS NULL THEN
    v_invoice_no := COALESCE(v_existing_no, nextval('public.job_invoice_no_seq')::text);
  END IF;

  INSERT INTO public.admin_billing_invoices (
    id, form_type, invoice_no, issued_on, bill_to_name, bill_to_address, bill_to_phone,
    bill_to_email, project, lines, adjustment_minor, subtotal_minor, total_minor,
    currency, notes, created_by, updated_by
  )
  VALUES (
    p_invoice_id, v_form, v_invoice_no, v_issued_on, v_name, v_address, v_phone,
    v_email, v_project, v_lines, v_adjustment, v_subtotal::integer, v_total::integer,
    'GHS', v_notes, p_recorded_by, p_recorded_by
  )
  ON CONFLICT (id) DO UPDATE SET
    form_type = EXCLUDED.form_type,
    invoice_no = EXCLUDED.invoice_no,
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
    updated_by = EXCLUDED.updated_by,
    updated_at = now()
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'formType', v_row.form_type,
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
    'updatedAt', v_row.updated_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_admin_payment_advice(
  p_advice_id uuid,
  p_recorded_by uuid,
  p_advice jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_line jsonb;
  v_earnings jsonb := '[]'::jsonb;
  v_reimbursements jsonb := '[]'::jsonb;
  v_deductions jsonb := '[]'::jsonb;
  v_description text;
  v_reference text;
  v_amount integer;
  v_amount_text text;
  v_earnings_total bigint := 0;
  v_reimbursements_total bigint := 0;
  v_deductions_total bigint := 0;
  v_net bigint;
  v_form text;
  v_advice_no text;
  v_existing_no text;
  v_period text;
  v_payment_date date;
  v_date_text text;
  v_name text;
  v_address text;
  v_phone text;
  v_email text;
  v_employee_id text;
  v_role text;
  v_department text;
  v_pay_type text;
  v_method text;
  v_account text;
  v_network text;
  v_reference_no text;
  v_row public.admin_payment_advices%ROWTYPE;
BEGIN
  IF p_advice_id IS NULL OR p_recorded_by IS NULL OR p_advice IS NULL THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;

  IF NOT public.admin_cash_payout_recorder_is_allowed(p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  v_form := p_advice ->> 'formType';
  IF v_form IS DISTINCT FROM 'w8ben' AND v_form IS DISTINCT FROM '1099' THEN
    RAISE EXCEPTION 'invalid_form_type';
  END IF;

  IF jsonb_typeof(p_advice -> 'earnings') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_advice -> 'earnings') < 1
     OR jsonb_array_length(p_advice -> 'earnings') > 20
     OR jsonb_typeof(p_advice -> 'reimbursements') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_advice -> 'reimbursements') > 20
     OR jsonb_typeof(p_advice -> 'deductions') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_advice -> 'deductions') > 20 THEN
    RAISE EXCEPTION 'invalid_lines';
  END IF;

  FOR v_line IN SELECT jsonb_array_elements(p_advice -> 'earnings')
  LOOP
    v_description := trim(COALESCE(v_line ->> 'description', ''));
    v_amount_text := v_line ->> 'amountMinor';
    IF v_description = '' OR length(v_description) > 200
       OR v_amount_text IS NULL OR v_amount_text !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;
    v_amount := v_amount_text::integer;
    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;
    v_earnings_total := v_earnings_total + v_amount;
    IF v_earnings_total > 2147483647 THEN
      RAISE EXCEPTION 'amount_too_large';
    END IF;
    v_earnings := v_earnings || jsonb_build_array(jsonb_build_object(
      'description', v_description,
      'amountMinor', v_amount
    ));
  END LOOP;

  FOR v_line IN SELECT jsonb_array_elements(p_advice -> 'reimbursements')
  LOOP
    v_description := trim(COALESCE(v_line ->> 'description', ''));
    v_reference := NULLIF(trim(COALESCE(v_line ->> 'reference', '')), '');
    v_amount_text := v_line ->> 'amountMinor';
    IF v_description = '' OR length(v_description) > 200
       OR (v_reference IS NOT NULL AND length(v_reference) > 40)
       OR v_amount_text IS NULL OR v_amount_text !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;
    v_amount := v_amount_text::integer;
    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;
    v_reimbursements_total := v_reimbursements_total + v_amount;
    IF v_reimbursements_total > 2147483647 THEN
      RAISE EXCEPTION 'amount_too_large';
    END IF;
    v_reimbursements := v_reimbursements || jsonb_build_array(jsonb_build_object(
      'description', v_description,
      'reference', v_reference,
      'amountMinor', v_amount
    ));
  END LOOP;

  FOR v_line IN SELECT jsonb_array_elements(p_advice -> 'deductions')
  LOOP
    v_description := trim(COALESCE(v_line ->> 'description', ''));
    v_amount_text := v_line ->> 'amountMinor';
    IF v_description = '' OR length(v_description) > 200
       OR v_amount_text IS NULL OR v_amount_text !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;
    v_amount := v_amount_text::integer;
    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'invalid_lines';
    END IF;
    v_deductions_total := v_deductions_total + v_amount;
    IF v_deductions_total > 2147483647 THEN
      RAISE EXCEPTION 'amount_too_large';
    END IF;
    v_deductions := v_deductions || jsonb_build_array(jsonb_build_object(
      'description', v_description,
      'amountMinor', v_amount
    ));
  END LOOP;

  v_net := v_earnings_total - v_deductions_total + v_reimbursements_total;
  IF v_net > 2147483647 OR v_net < -2147483648 THEN
    RAISE EXCEPTION 'amount_too_large';
  END IF;

  v_date_text := p_advice ->> 'paymentDate';
  IF v_date_text IS NULL OR v_date_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;
  v_payment_date := v_date_text::date;

  v_name := trim(COALESCE(p_advice ->> 'paidToName', ''));
  v_period := trim(COALESCE(p_advice ->> 'payPeriod', ''));
  v_address := NULLIF(trim(COALESCE(p_advice ->> 'paidToAddress', '')), '');
  v_phone := NULLIF(trim(COALESCE(p_advice ->> 'paidToPhone', '')), '');
  v_email := NULLIF(lower(trim(COALESCE(p_advice ->> 'paidToEmail', ''))), '');
  v_employee_id := NULLIF(trim(COALESCE(p_advice ->> 'employeeId', '')), '');
  v_role := NULLIF(trim(COALESCE(p_advice ->> 'role', '')), '');
  v_department := NULLIF(trim(COALESCE(p_advice ->> 'department', '')), '');
  v_pay_type := NULLIF(trim(COALESCE(p_advice ->> 'payType', '')), '');
  v_method := NULLIF(trim(COALESCE(p_advice ->> 'payMethod', '')), '');
  v_account := NULLIF(trim(COALESCE(p_advice ->> 'payAccount', '')), '');
  v_network := NULLIF(trim(COALESCE(p_advice ->> 'payNetwork', '')), '');
  v_reference_no := NULLIF(trim(COALESCE(p_advice ->> 'payReference', '')), '');

  IF v_name = '' OR length(v_name) > 160
     OR v_period = '' OR length(v_period) > 40
     OR (v_address IS NOT NULL AND length(v_address) > 500)
     OR (v_phone IS NOT NULL AND length(v_phone) > 32)
     OR (v_email IS NOT NULL AND length(v_email) > 200)
     OR (v_employee_id IS NOT NULL AND length(v_employee_id) > 40)
     OR (v_role IS NOT NULL AND length(v_role) > 80)
     OR (v_department IS NOT NULL AND length(v_department) > 80)
     OR (v_pay_type IS NOT NULL AND length(v_pay_type) > 80)
     OR (v_method IS NOT NULL AND length(v_method) > 80)
     OR (v_account IS NOT NULL AND length(v_account) > 40)
     OR (v_network IS NOT NULL AND length(v_network) > 40)
     OR (v_reference_no IS NOT NULL AND length(v_reference_no) > 40) THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;

  IF v_email IS NOT NULL AND v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  SELECT advice_no INTO v_existing_no
  FROM public.admin_payment_advices
  WHERE id = p_advice_id
  FOR UPDATE;

  v_advice_no := NULLIF(trim(COALESCE(p_advice ->> 'adviceNo', '')), '');
  IF v_advice_no IS NOT NULL AND length(v_advice_no) > 40 THEN
    RAISE EXCEPTION 'invalid_invoice';
  END IF;
  IF v_advice_no IS NULL THEN
    v_advice_no := COALESCE(v_existing_no, 'PAY-' || nextval('public.payment_advice_no_seq')::text);
  END IF;

  INSERT INTO public.admin_payment_advices (
    id, form_type, advice_no, pay_period, payment_date, paid_to_name, paid_to_address,
    paid_to_email, paid_to_phone, employee_id, role_name, department, pay_type,
    earnings, reimbursements, deductions, earnings_minor, reimbursements_minor,
    deductions_minor, net_minor, currency, pay_method, pay_account, pay_network,
    pay_reference, created_by, updated_by
  )
  VALUES (
    p_advice_id, v_form, v_advice_no, v_period, v_payment_date, v_name, v_address,
    v_email, v_phone, v_employee_id, v_role, v_department, v_pay_type,
    v_earnings, v_reimbursements, v_deductions, v_earnings_total::integer,
    v_reimbursements_total::integer, v_deductions_total::integer, v_net::integer,
    'GHS', v_method, v_account, v_network, v_reference_no, p_recorded_by, p_recorded_by
  )
  ON CONFLICT (id) DO UPDATE SET
    form_type = EXCLUDED.form_type,
    advice_no = EXCLUDED.advice_no,
    pay_period = EXCLUDED.pay_period,
    payment_date = EXCLUDED.payment_date,
    paid_to_name = EXCLUDED.paid_to_name,
    paid_to_address = EXCLUDED.paid_to_address,
    paid_to_email = EXCLUDED.paid_to_email,
    paid_to_phone = EXCLUDED.paid_to_phone,
    employee_id = EXCLUDED.employee_id,
    role_name = EXCLUDED.role_name,
    department = EXCLUDED.department,
    pay_type = EXCLUDED.pay_type,
    earnings = EXCLUDED.earnings,
    reimbursements = EXCLUDED.reimbursements,
    deductions = EXCLUDED.deductions,
    earnings_minor = EXCLUDED.earnings_minor,
    reimbursements_minor = EXCLUDED.reimbursements_minor,
    deductions_minor = EXCLUDED.deductions_minor,
    net_minor = EXCLUDED.net_minor,
    pay_method = EXCLUDED.pay_method,
    pay_account = EXCLUDED.pay_account,
    pay_network = EXCLUDED.pay_network,
    pay_reference = EXCLUDED.pay_reference,
    updated_by = EXCLUDED.updated_by,
    updated_at = now()
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'formType', v_row.form_type,
    'adviceNo', v_row.advice_no,
    'payPeriod', v_row.pay_period,
    'paymentDate', to_char(v_row.payment_date, 'YYYY-MM-DD'),
    'paidToName', v_row.paid_to_name,
    'paidToAddress', v_row.paid_to_address,
    'paidToEmail', v_row.paid_to_email,
    'paidToPhone', v_row.paid_to_phone,
    'employeeId', v_row.employee_id,
    'role', v_row.role_name,
    'department', v_row.department,
    'payType', v_row.pay_type,
    'earnings', v_row.earnings,
    'reimbursements', v_row.reimbursements,
    'deductions', v_row.deductions,
    'earningsMinor', v_row.earnings_minor,
    'reimbursementsMinor', v_row.reimbursements_minor,
    'deductionsMinor', v_row.deductions_minor,
    'netMinor', v_row.net_minor,
    'currency', v_row.currency,
    'payMethod', v_row.pay_method,
    'payAccount', v_row.pay_account,
    'payNetwork', v_row.pay_network,
    'payReference', v_row.pay_reference,
    'updatedAt', v_row.updated_at
  );
END;
$function$;

COMMENT ON FUNCTION public.upsert_admin_billing_invoice(uuid, uuid, jsonb) IS
  'Create or update a custom invoice that is not tied to a booking. form_type is w8ben or 1099. Totals are pesewas.';

COMMENT ON FUNCTION public.upsert_admin_payment_advice(uuid, uuid, jsonb) IS
  'Create or update a payment advice. Net pay is earnings minus deductions plus reimbursements, in pesewas. form_type is w8ben or 1099.';
