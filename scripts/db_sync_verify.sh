#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the Mithril shadow PostgreSQL database}"
: "${SNAPSHOT_DIR:?Set SNAPSHOT_DIR to the snapshot directory used for restore}"

for command_name in psql python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
done

SOURCE_COUNTS="$SNAPSHOT_DIR/public_row_counts.csv"
TARGET_COUNTS="$SNAPSHOT_DIR/target_public_row_counts.csv"
REPORT="$SNAPSHOT_DIR/parity_report.csv"

if [[ ! -f "$SOURCE_COUNTS" ]]; then
  echo "Missing source row-count manifest: $SOURCE_COUNTS" >&2
  exit 1
fi

# FORCE ROW LEVEL SECURITY hides rows from the table owner. Fly MPG restore
# users are not superusers, so verification temporarily lifts FORCE inside a
# transaction and rolls it back afterward.
psql "$TARGET_DATABASE_URL" -X -q -v ON_ERROR_STOP=1 --csv > "$TARGET_COUNTS" <<'SQL'
BEGIN;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relforcerowsecurity
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend d
        WHERE d.objid = c.oid
          AND d.deptype = 'e'
      )
  LOOP
    BEGIN
      EXECUTE format('ALTER TABLE %I.%I NO FORCE ROW LEVEL SECURITY', r.nspname, r.relname);
    EXCEPTION
      WHEN insufficient_privilege THEN
        RAISE NOTICE 'Could not lift FORCE RLS on %.%', r.nspname, r.relname;
    END;
  END LOOP;
END
$$;

CREATE TEMP TABLE mithril_target_row_counts (
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
    INSERT INTO mithril_target_row_counts(schema_name, table_name, row_count)
    VALUES (r.schemaname, r.tablename, v_count);
  END LOOP;
END
$$;

SELECT schema_name, table_name, row_count
FROM mithril_target_row_counts
ORDER BY schema_name, table_name;

ROLLBACK;
SQL

python3 - "$SOURCE_COUNTS" "$TARGET_COUNTS" "$REPORT" <<'PY'
import csv
import sys

source_path, target_path, report_path = sys.argv[1:]

def load(path):
    rows = {}
    with open(path, newline='', encoding='utf-8') as handle:
        for row in csv.DictReader(handle):
            key = (row['schema_name'], row['table_name'])
            rows[key] = int(row['row_count'])
    return rows

source = load(source_path)
target = load(target_path)
keys = sorted(set(source) | set(target))
failures = 0

with open(report_path, 'w', newline='', encoding='utf-8') as handle:
    writer = csv.writer(handle)
    writer.writerow(['schema_name', 'table_name', 'source_rows', 'target_rows', 'status'])
    for schema_name, table_name in keys:
        src = source.get((schema_name, table_name))
        dst = target.get((schema_name, table_name))
        if src is None:
            status = 'target_only'
        elif dst is None:
            status = 'missing_target'
        elif src != dst:
            status = 'row_count_mismatch'
        else:
            status = 'ok'
        if status != 'ok':
            failures += 1
        writer.writerow([schema_name, table_name, src, dst, status])

print(f'Compared {len(keys)} public tables; failures={failures}')
if failures:
    sys.exit(2)
PY

SOURCE_AUTH_ROWS="$(python3 - "$SNAPSHOT_DIR/auth_identity_projection.csv" <<'PY'
import csv
import sys
with open(sys.argv[1], newline='', encoding='utf-8') as handle:
    print(sum(1 for _ in csv.DictReader(handle)))
PY
)"
TARGET_AUTH_ROWS="$(psql "$TARGET_DATABASE_URL" -X -Atqc 'select count(*) from auth.users')"

if [[ "$SOURCE_AUTH_ROWS" != "$TARGET_AUTH_ROWS" ]]; then
  echo "Sanitized auth identity count mismatch: source=$SOURCE_AUTH_ROWS target=$TARGET_AUTH_ROWS" >&2
  exit 3
fi

echo "✓ Public table row counts match the snapshot"
echo "✓ Sanitized auth identity projection count matches ($TARGET_AUTH_ROWS)"
echo "Parity report: $REPORT"
