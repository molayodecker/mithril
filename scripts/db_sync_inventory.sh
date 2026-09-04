#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_DATABASE_URL:?Set SOURCE_DATABASE_URL to the current Instaclean production PostgreSQL connection string}"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required." >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${DB_SYNC_OUTPUT_DIR:-.artifacts/db-sync/$STAMP}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR" 2>/dev/null || true

PSQL=(psql "$SOURCE_DATABASE_URL" -X -q -v ON_ERROR_STOP=1)

echo "Inventorying production database into $OUT_DIR"

"${PSQL[@]}" --csv -c "
SELECT
  current_database() AS database_name,
  current_user AS database_user,
  current_setting('server_version') AS server_version,
  now() AT TIME ZONE 'UTC' AS captured_at_utc;
" > "$OUT_DIR/source_database.csv"

"${PSQL[@]}" --csv -c "
SELECT
  n.nspname AS schema_name,
  c.relname AS table_name,
  pg_total_relation_size(c.oid) AS total_bytes,
  c.reltuples::bigint AS estimated_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n.nspname, c.relname;
" > "$OUT_DIR/tables.csv"

"${PSQL[@]}" --csv > "$OUT_DIR/public_row_counts.csv" <<'SQL'
CREATE TEMP TABLE mithril_row_counts (
  schema_name text NOT NULL,
  table_name text NOT NULL,
  row_count bigint NOT NULL
);

DO $$
DECLARE
  r record;
  v_count bigint;
BEGIN
  FOR r IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname = 'public'
    ORDER BY tablename
  LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', r.schemaname, r.tablename)
      INTO v_count;
    INSERT INTO mithril_row_counts(schema_name, table_name, row_count)
    VALUES (r.schemaname, r.tablename, v_count);
  END LOOP;
END
$$;

SELECT schema_name, table_name, row_count
FROM mithril_row_counts
ORDER BY schema_name, table_name;
SQL

"${PSQL[@]}" --csv -c "
SELECT
  e.extname AS extension_name,
  e.extversion AS extension_version,
  n.nspname AS schema_name
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname;
" > "$OUT_DIR/extensions.csv"

"${PSQL[@]}" --csv -c "
WITH objects AS (
  SELECT 'table'::text AS object_type, count(*)::bigint AS object_count
  FROM pg_tables WHERE schemaname = 'public'
  UNION ALL
  SELECT 'view', count(*) FROM pg_views WHERE schemaname = 'public'
  UNION ALL
  SELECT 'materialized_view', count(*) FROM pg_matviews WHERE schemaname = 'public'
  UNION ALL
  SELECT 'sequence', count(*) FROM pg_sequences WHERE schemaname = 'public'
  UNION ALL
  SELECT 'function_or_procedure', count(*)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
  UNION ALL
  SELECT 'trigger', count(*)
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal
  UNION ALL
  SELECT 'policy', count(*) FROM pg_policies WHERE schemaname = 'public'
)
SELECT object_type, object_count FROM objects ORDER BY object_type;
" > "$OUT_DIR/public_object_counts.csv"

"${PSQL[@]}" --csv -c "
SELECT
  tc.table_schema,
  tc.table_name,
  tc.constraint_name,
  ccu.table_schema AS referenced_schema,
  ccu.table_name AS referenced_table,
  ccu.column_name AS referenced_column
FROM information_schema.table_constraints tc
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
  AND ccu.constraint_schema = tc.constraint_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
  AND ccu.table_schema <> 'public'
ORDER BY tc.table_name, tc.constraint_name;
" > "$OUT_DIR/external_foreign_keys.csv"

"${PSQL[@]}" --csv -c "
WITH candidates AS MATERIALIZED (
  SELECT
    p.oid,
    n.nspname AS function_schema,
    p.proname AS function_name
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind IN ('f', 'p')
)
SELECT
  function_schema,
  function_name,
  pg_get_function_identity_arguments(oid) AS arguments
FROM candidates
WHERE position('auth.' in lower(pg_get_functiondef(oid))) > 0
ORDER BY function_name, pg_get_function_identity_arguments(oid);
" > "$OUT_DIR/functions_referencing_auth.csv"

"${PSQL[@]}" --csv -c "
SELECT 'view'::text AS object_type, schemaname, viewname AS object_name
FROM pg_views
WHERE schemaname = 'public'
  AND position('auth.' in lower(definition)) > 0
UNION ALL
SELECT 'materialized_view', schemaname, matviewname
FROM pg_matviews
WHERE schemaname = 'public'
  AND position('auth.' in lower(definition)) > 0
ORDER BY object_type, object_name;
" > "$OUT_DIR/views_referencing_auth.csv"

"${PSQL[@]}" -At -c "
SELECT DISTINCT role_name
FROM pg_policies p
CROSS JOIN LATERAL unnest(p.roles) AS role_name
WHERE p.schemaname = 'public'
  AND role_name <> 'public'
ORDER BY role_name;
" > "$OUT_DIR/public_policy_roles.txt"

# Shadow roles are deliberately limited to application-facing roles. We do not
# recreate Supabase's internal role topology on Fly Postgres.
"${PSQL[@]}" -At -c "
WITH role_names AS (
  SELECT DISTINCT role_name::text
  FROM pg_policies p
  CROSS JOIN LATERAL unnest(p.roles) AS role_name
  WHERE p.schemaname = 'public'
    AND role_name <> 'public'
  UNION
  SELECT rolname
  FROM pg_roles
  WHERE rolname IN ('anon', 'authenticated', 'service_role')
)
SELECT role_name
FROM role_names
ORDER BY role_name;
" > "$OUT_DIR/public_shadow_roles.txt"

# Capture the effective runtime privileges those shadow roles have on public
# objects. The main dump intentionally omits ACLs so Supabase-internal roles are
# not recreated. These grants are reviewed and applied after restore instead.
"${PSQL[@]}" -At -c "
WITH role_names AS (
  SELECT DISTINCT role_name::text
  FROM pg_policies p
  CROSS JOIN LATERAL unnest(p.roles) AS role_name
  WHERE p.schemaname = 'public'
    AND role_name <> 'public'
  UNION
  SELECT rolname
  FROM pg_roles
  WHERE rolname IN ('anon', 'authenticated', 'service_role')
), grants AS (
  SELECT
    10 AS sort_order,
    format('GRANT USAGE ON SCHEMA public TO %I;', r.role_name) AS ddl
  FROM role_names r
  WHERE has_schema_privilege(r.role_name, 'public', 'USAGE')

  UNION ALL

  SELECT
    20,
    format('GRANT %s ON TABLE %I.%I TO %I;', privilege_name, n.nspname, c.relname, r.role_name)
  FROM role_names r
  JOIN pg_class c ON c.relkind IN ('r', 'p', 'v', 'm', 'f')
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
  CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS privilege_name
  WHERE has_table_privilege(r.role_name, c.oid, privilege_name)

  UNION ALL

  SELECT
    30,
    format('GRANT %s ON SEQUENCE %I.%I TO %I;', privilege_name, n.nspname, c.relname, r.role_name)
  FROM role_names r
  JOIN pg_class c ON c.relkind = 'S'
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
  CROSS JOIN unnest(ARRAY['SELECT','USAGE','UPDATE']) AS privilege_name
  WHERE has_sequence_privilege(r.role_name, c.oid, privilege_name)

  UNION ALL

  SELECT
    40,
    format(
      'GRANT EXECUTE ON %s %I.%I(%s) TO %I;',
      CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid),
      r.role_name
    )
  FROM role_names r
  JOIN pg_proc p ON p.prokind IN ('f', 'p')
  JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
  WHERE has_function_privilege(r.role_name, p.oid, 'EXECUTE')

  UNION ALL

  SELECT
    50,
    format('GRANT USAGE ON TYPE %I.%I TO %I;', n.nspname, t.typname, r.role_name)
  FROM role_names r
  JOIN pg_type t ON t.typtype IN ('e', 'd', 'r')
  JOIN pg_namespace n ON n.oid = t.typnamespace AND n.nspname = 'public'
  WHERE has_type_privilege(r.role_name, t.oid, 'USAGE')
)
SELECT DISTINCT ddl
FROM grants
ORDER BY ddl;
" > "$OUT_DIR/public_shadow_grants.sql"

# Preserve the complete auth.users column *shape* without copying Supabase Auth
# credentials. All shadow columns are nullable; only id receives a primary key.
"${PSQL[@]}" -At -c "
WITH cols AS (
  SELECT
    a.attnum,
    format('  %I %s', a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)) AS definition
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'auth'
    AND c.relname = 'users'
    AND a.attnum > 0
    AND NOT a.attisdropped
)
SELECT
  'CREATE TABLE auth.users (' || E'\\n' ||
  string_agg(definition, E',\\n' ORDER BY attnum) ||
  E'\\n);\\nALTER TABLE auth.users ADD PRIMARY KEY (id);'
FROM cols;
" > "$OUT_DIR/auth_users_shadow_schema.sql"

"${PSQL[@]}" -At -c "
SELECT ddl
FROM (
  SELECT
    1 AS sort_order,
    format('CREATE SCHEMA IF NOT EXISTS %I;', n.nspname) AS ddl
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname <> 'plpgsql'
  UNION ALL
  SELECT
    2 AS sort_order,
    format('CREATE EXTENSION IF NOT EXISTS %I WITH SCHEMA %I;', e.extname, n.nspname) AS ddl
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname <> 'plpgsql'
) statements
ORDER BY sort_order, ddl;
" > "$OUT_DIR/required_extensions.sql"

printf '%s\n' "$OUT_DIR"
