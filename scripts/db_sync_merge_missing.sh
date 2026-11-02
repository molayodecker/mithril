#!/usr/bin/env bash
set -euo pipefail

# Insert rows that exist on SOURCE and are missing on TARGET.
# Existing target rows are kept. The source is read-only.
# This does not call db_sync_restore_shadow.sh and does not drop public tables.

: "${SOURCE_DATABASE_URL:?Set SOURCE_DATABASE_URL to Supabase instaclean-prod (session/direct, port 5432)}"
: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the Mithril database that should keep its current rows}"

if [[ "$SOURCE_DATABASE_URL" == "$TARGET_DATABASE_URL" ]]; then
  echo "SOURCE_DATABASE_URL and TARGET_DATABASE_URL are identical. Refusing merge." >&2
  exit 1
fi

if [[ "$TARGET_DATABASE_URL" == *"supabase.co"* || "$TARGET_DATABASE_URL" == *"supabase.com"* ]]; then
  echo "TARGET_DATABASE_URL looks like Supabase. Refusing to write to it." >&2
  exit 1
fi

if [[ "$SOURCE_DATABASE_URL" == *":6543/"* || "$SOURCE_DATABASE_URL" == *":6543" ]]; then
  echo "SOURCE_DATABASE_URL looks like a transaction pooler (port 6543). Use session mode (5432) or a direct connection." >&2
  exit 1
fi

if [[ ! "${MERGE_STAGE_SCHEMA:-}" =~ ^merge_missing_[0-9]+_[0-9]+$ ]]; then
  MERGE_STAGE_SCHEMA="merge_missing_$$_$(date +%s)"
  export MERGE_STAGE_SCHEMA
fi

CLEANUP_STAGE=0
cleanup_stage() {
  if [[ "$CLEANUP_STAGE" != "1" ]]; then
    return 0
  fi
  if [[ -z "${TARGET_DATABASE_URL:-}" || -z "${MERGE_STAGE_SCHEMA:-}" ]]; then
    return 0
  fi
  psql "$TARGET_DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
    -c "DROP SCHEMA IF EXISTS \"${MERGE_STAGE_SCHEMA}\" CASCADE" >/dev/null 2>&1 || true
  psql "$TARGET_DATABASE_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1 || true
DO $$
DECLARE
  rel record;
BEGIN
  FOR rel IN
    SELECT n.nspname AS schema_name, c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname IN ('public', 'auth')
      AND EXISTS (
        SELECT 1 FROM pg_policy pol
        WHERE pol.polrelid = c.oid
          AND pol.polname IN ('merge_missing_select', 'merge_missing_insert')
      )
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS merge_missing_select ON %I.%I', rel.schema_name, rel.table_name);
    EXECUTE format('DROP POLICY IF EXISTS merge_missing_insert ON %I.%I', rel.schema_name, rel.table_name);
  END LOOP;
END $$;
SQL
}
trap cleanup_stage EXIT

if [[ "${CONFIRM_MISSING_MERGE:-}" == "YES" && "${DRY_RUN:-}" != "YES" ]]; then
  export MERGE_MODE=apply
  CLEANUP_STAGE=1
  echo "Insert-only merge. Existing target rows stay. Source is not modified."
else
  export MERGE_MODE=dry-run
  echo "Dry run only. No rows will be written."
  echo "Set CONFIRM_MISSING_MERGE=YES to insert missing primary keys. Existing rows stay."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/db_sync_merge_missing.py"
