#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_DATABASE_URL:?Set SOURCE_DATABASE_URL to the current Instaclean production PostgreSQL connection string}"

for command_name in psql pg_dump; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
done

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "sha256sum or shasum is required." >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${DB_SYNC_OUTPUT_DIR:-.artifacts/db-sync/$STAMP}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEEPER_PID=""
KEEPER_IN_FD=""
KEEPER_OUT_FD=""
PG_SNAPSHOT_ID=""

cleanup_snapshot_keeper() {
  if [[ -n "${KEEPER_IN_FD:-}" ]]; then
    printf 'ROLLBACK;\n\\q\n' >&"$KEEPER_IN_FD" 2>/dev/null || true
  fi
  if [[ -n "${KEEPER_PID:-}" ]]; then
    wait "$KEEPER_PID" 2>/dev/null || true
  fi
  KEEPER_PID=""
  KEEPER_IN_FD=""
  KEEPER_OUT_FD=""
}
trap cleanup_snapshot_keeper EXIT

# Keep one read-only repeatable-read transaction open while every data-bearing
# artifact is captured. pg_dump and psql consumers import this exact snapshot,
# preventing live writes from producing mismatched row counts/dump/auth data.
coproc DB_SYNC_SNAPSHOT_KEEPER {
  psql "$SOURCE_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1
}
KEEPER_PID="$DB_SYNC_SNAPSHOT_KEEPER_PID"
KEEPER_OUT_FD="${DB_SYNC_SNAPSHOT_KEEPER[0]}"
KEEPER_IN_FD="${DB_SYNC_SNAPSHOT_KEEPER[1]}"

printf '%s\n' \
  'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;' \
  'SELECT pg_export_snapshot();' \
  >&"$KEEPER_IN_FD"

if ! IFS= read -r PG_SNAPSHOT_ID <&"$KEEPER_OUT_FD"; then
  echo "Failed to export a PostgreSQL snapshot. Use a direct/session PostgreSQL connection, not a transaction pooler." >&2
  exit 1
fi

if [[ -z "$PG_SNAPSHOT_ID" ]]; then
  echo "PostgreSQL returned an empty exported snapshot id." >&2
  exit 1
fi

printf '%s\n' "$PG_SNAPSHOT_ID" > "$OUT_DIR/snapshot_id.txt"
chmod 600 "$OUT_DIR/snapshot_id.txt" 2>/dev/null || true

echo "Exported consistent PostgreSQL snapshot: $PG_SNAPSHOT_ID"

# Test/debug coordination only. When supplied, callers may deliberately mutate
# the live source after the snapshot is exported and before capture continues.
if [[ -n "${DB_SYNC_SNAPSHOT_READY_FILE:-}" ]]; then
  printf '%s\n' "$PG_SNAPSHOT_ID" > "$DB_SYNC_SNAPSHOT_READY_FILE"
fi
if [[ -n "${DB_SYNC_SNAPSHOT_RELEASE_FILE:-}" ]]; then
  while [[ ! -e "$DB_SYNC_SNAPSHOT_RELEASE_FILE" ]]; do
    sleep 0.05
  done
fi

# Catalog diagnostics are useful context. Data-bearing manifests below are
# regenerated from the exported snapshot so they match public.dump exactly.
DB_SYNC_OUTPUT_DIR="$OUT_DIR" bash "$SCRIPT_DIR/db_sync_inventory.sh" >/dev/null

echo "Capturing exact public row counts from the exported snapshot..."
psql "$SOURCE_DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -v snapshot_id="$PG_SNAPSHOT_ID" --csv > "$OUT_DIR/public_row_counts.csv" <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET TRANSACTION SNAPSHOT :'snapshot_id';

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
COMMIT;
SQL

echo "Creating full public-schema logical snapshot..."
pg_dump "$SOURCE_DATABASE_URL" \
  --format=custom \
  --schema=public \
  --snapshot="$PG_SNAPSHOT_ID" \
  --no-owner \
  --no-privileges \
  --file="$OUT_DIR/public.dump"

# This is intentionally not a dump of auth.users. It carries only the identity
# columns needed to satisfy public FK relationships and parity-test current
# account/trust logic. Password hashes, recovery/confirmation tokens, MFA,
# sessions, refresh tokens, and provider identities are not copied.
echo "Exporting sanitized auth identity projection from the same snapshot..."
psql "$SOURCE_DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -v snapshot_id="$PG_SNAPSHOT_ID" --csv > "$OUT_DIR/auth_identity_projection.csv" <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET TRANSACTION SNAPSHOT :'snapshot_id';
SELECT
  id,
  email,
  phone,
  created_at,
  updated_at,
  email_confirmed_at,
  phone_confirmed_at,
  last_sign_in_at,
  banned_until,
  deleted_at,
  COALESCE(is_anonymous, false) AS is_anonymous
FROM auth.users
ORDER BY id;
COMMIT;
SQL
chmod 600 "$OUT_DIR/auth_identity_projection.csv" 2>/dev/null || true

# The exported snapshot is no longer needed once all data-bearing artifacts are
# complete. Close it promptly so production vacuum is not held back.
cleanup_snapshot_keeper
trap - EXIT

pg_dump --version > "$OUT_DIR/pg_dump_version.txt"
psql --version > "$OUT_DIR/psql_version.txt"

CHECKSUM_FILES=(
  public.dump
  auth_identity_projection.csv
  auth_users_shadow_schema.sql
  public_row_counts.csv
  public_object_counts.csv
  external_foreign_keys.csv
  functions_referencing_auth.csv
  views_referencing_auth.csv
  public_policy_roles.txt
  public_shadow_roles.txt
  public_shadow_grants.sql
  extensions.csv
  required_extensions.sql
  snapshot_id.txt
)

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && sha256sum "${CHECKSUM_FILES[@]}" > SHA256SUMS)
else
  (cd "$OUT_DIR" && shasum -a 256 "${CHECKSUM_FILES[@]}" > SHA256SUMS)
fi

cat > "$OUT_DIR/README.txt" <<TXT
Instaclean production shadow snapshot
Captured: $STAMP
PostgreSQL snapshot: $PG_SNAPSHOT_ID

public.dump
  Custom-format pg_dump of the entire public schema and its data, captured from
  the same repeatable-read snapshot as row counts and sanitized auth identity.

auth_users_shadow_schema.sql
  Column/type shape of production auth.users, with nullable columns and only an
  id primary key. It contains no Auth rows or credentials.

auth_identity_projection.csv
  Sanitized identity bridge only. No passwords, auth tokens, sessions, MFA,
  provider identities, or recovery/confirmation secrets are included.

public_row_counts.csv
  Exact public table counts from the same exported snapshot as public.dump.

public_shadow_roles.txt / public_shadow_grants.sql
  Limited application-facing roles and their effective public runtime grants.
  Supabase's internal role topology is intentionally not cloned.

This directory may contain production customer data. Keep it private and do not
commit or upload it to GitHub.
TXT

printf '%s\n' "$OUT_DIR"
