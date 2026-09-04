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
  SELECT 'function', count(*)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
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
SELECT
  n.nspname AS function_schema,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS arguments
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND position('auth.' in lower(pg_get_functiondef(p.oid))) > 0
ORDER BY p.proname, pg_get_function_identity_arguments(p.oid);
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
