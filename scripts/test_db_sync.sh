#!/usr/bin/env bash
set -euo pipefail

for command_name in psql pg_dump pg_restore python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required for the database sync integration test." >&2
    exit 1
  fi
done

ADMIN_URL="${DB_SYNC_TEST_ADMIN_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
SOURCE_DB="mithril_sync_source"
TARGET_DB="mithril_sync_target"
ADMIN_PREFIX="${ADMIN_URL%/*}"
SOURCE_URL="$ADMIN_PREFIX/$SOURCE_DB"
TARGET_URL="$ADMIN_PREFIX/$TARGET_DB"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SNAPSHOT_DIR="$TMP_DIR/snapshot"
READY_FILE="$TMP_DIR/snapshot-ready"
RELEASE_FILE="$TMP_DIR/snapshot-release"
SNAPSHOT_PID=""

cleanup() {
  if [[ -n "${SNAPSHOT_PID:-}" ]]; then
    kill "$SNAPSHOT_PID" >/dev/null 2>&1 || true
    wait "$SNAPSHOT_PID" >/dev/null 2>&1 || true
  fi
  psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('$SOURCE_DB', '$TARGET_DB') AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $SOURCE_DB;" >/dev/null 2>&1 || true
  psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $TARGET_DB;" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cleanup
trap cleanup EXIT

psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 <<SQL
CREATE DATABASE $SOURCE_DB;
CREATE DATABASE $TARGET_DB;
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END
\$\$;
SQL

psql "$SOURCE_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text,
  phone text,
  encrypted_password text,
  recovery_token text,
  created_at timestamptz,
  updated_at timestamptz,
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz,
  last_sign_in_at timestamptz,
  banned_until timestamptz,
  deleted_at timestamptz,
  is_anonymous boolean DEFAULT false
);

CREATE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$ SELECT null::uuid $$;

CREATE TABLE public.users (
  id uuid PRIMARY KEY REFERENCES auth.users(id),
  email text NOT NULL
);

CREATE TABLE public.bookings (
  id uuid PRIMARY KEY,
  customer_id uuid NOT NULL REFERENCES auth.users(id),
  status text NOT NULL
);

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_self ON public.users
  FOR SELECT TO authenticated
  USING (auth.uid() = id);

CREATE FUNCTION public.lookup_shadow_email(target_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT email FROM auth.users WHERE id = target_user_id
$$;

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON public.users TO authenticated;
REVOKE ALL ON FUNCTION public.lookup_shadow_email(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lookup_shadow_email(uuid) TO authenticated;

INSERT INTO auth.users (
  id, email, phone, encrypted_password, recovery_token,
  created_at, updated_at, email_confirmed_at, phone_confirmed_at,
  last_sign_in_at, banned_until, deleted_at, is_anonymous
) VALUES (
  '11111111-1111-1111-1111-111111111111',
  'shadow@example.com',
  '+15555550123',
  'SECRET_HASH_MUST_NOT_COPY',
  'SECRET_RECOVERY_MUST_NOT_COPY',
  now(), now(), now(), now(), now(), NULL, NULL, false
);

INSERT INTO public.users(id, email)
VALUES ('11111111-1111-1111-1111-111111111111', 'shadow@example.com');

INSERT INTO public.bookings(id, customer_id, status)
VALUES (
  '22222222-2222-2222-2222-222222222222',
  '11111111-1111-1111-1111-111111111111',
  'confirmed'
);
SQL

SOURCE_DATABASE_URL="$SOURCE_URL" \
DB_SYNC_OUTPUT_DIR="$SNAPSHOT_DIR" \
DB_SYNC_SNAPSHOT_READY_FILE="$READY_FILE" \
DB_SYNC_SNAPSHOT_RELEASE_FILE="$RELEASE_FILE" \
bash "$ROOT_DIR/scripts/db_sync_snapshot.sh" >/dev/null &
SNAPSHOT_PID=$!

for _ in $(seq 1 200); do
  [[ -s "$READY_FILE" ]] && break
  sleep 0.05
done
if [[ ! -s "$READY_FILE" ]]; then
  echo "Snapshot script did not expose its exported snapshot in time." >&2
  exit 1
fi

# These rows are committed after the exported snapshot exists. A correct
# point-in-time capture must exclude them from row counts, public.dump and the
# sanitized auth projection even though the source keeps accepting writes.
psql "$SOURCE_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO auth.users (
  id, email, phone, encrypted_password, recovery_token,
  created_at, updated_at, is_anonymous
) VALUES (
  '33333333-3333-3333-3333-333333333333',
  'late@example.com',
  '+15555550999',
  'LATE_SECRET_HASH',
  'LATE_SECRET_RECOVERY',
  now(), now(), false
);
INSERT INTO public.users(id, email)
VALUES ('33333333-3333-3333-3333-333333333333', 'late@example.com');
SQL

touch "$RELEASE_FILE"
wait "$SNAPSHOT_PID"
SNAPSHOT_PID=""

if grep -q 'SECRET_HASH_MUST_NOT_COPY\|SECRET_RECOVERY_MUST_NOT_COPY\|LATE_SECRET_HASH\|LATE_SECRET_RECOVERY' "$SNAPSHOT_DIR/auth_identity_projection.csv"; then
  echo "Auth secret leaked into sanitized identity projection." >&2
  exit 1
fi

if grep -q 'late@example.com' "$SNAPSHOT_DIR/auth_identity_projection.csv"; then
  echo "Sanitized auth projection escaped the exported point-in-time snapshot." >&2
  exit 1
fi

SOURCE_DATABASE_URL="$SOURCE_URL" \
TARGET_DATABASE_URL="$TARGET_URL" \
SNAPSHOT_DIR="$SNAPSHOT_DIR" \
CONFIRM_SHADOW_RESTORE=YES \
bash "$ROOT_DIR/scripts/db_sync_restore_shadow.sh" >/dev/null

TARGET_DATABASE_URL="$TARGET_URL" \
SNAPSHOT_DIR="$SNAPSHOT_DIR" \
bash "$ROOT_DIR/scripts/db_sync_verify.sh" >/dev/null

# A live sync is a replace, not a one-shot import. Restoring the same snapshot
# a second time must still verify.
SOURCE_DATABASE_URL="$SOURCE_URL" \
TARGET_DATABASE_URL="$TARGET_URL" \
SNAPSHOT_DIR="$SNAPSHOT_DIR" \
CONFIRM_SHADOW_RESTORE=YES \
bash "$ROOT_DIR/scripts/db_sync_restore_shadow.sh" >/dev/null

TARGET_DATABASE_URL="$TARGET_URL" \
SNAPSHOT_DIR="$SNAPSHOT_DIR" \
bash "$ROOT_DIR/scripts/db_sync_verify.sh" >/dev/null

SECRET_VALUES="$(psql "$TARGET_URL" -X -Atqc "SELECT coalesce(encrypted_password, '<null>') || '|' || coalesce(recovery_token, '<null>') FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111'")"
if [[ "$SECRET_VALUES" != "<null>|<null>" ]]; then
  echo "Auth secret-shaped columns were unexpectedly populated: $SECRET_VALUES" >&2
  exit 1
fi

TARGET_USER_COUNT="$(psql "$TARGET_URL" -X -Atqc 'SELECT count(*) FROM public.users')"
if [[ "$TARGET_USER_COUNT" != "1" ]]; then
  echo "Point-in-time public dump included rows committed after export: $TARGET_USER_COUNT" >&2
  exit 1
fi

LOOKUP_EMAIL="$(psql "$TARGET_URL" -X -Atqc "SELECT public.lookup_shadow_email('11111111-1111-1111-1111-111111111111')")"
if [[ "$LOOKUP_EMAIL" != "shadow@example.com" ]]; then
  echo "Restored public function cannot read sanitized auth identity: $LOOKUP_EMAIL" >&2
  exit 1
fi

POLICY_COUNT="$(psql "$TARGET_URL" -X -Atqc "SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'users' AND policyname = 'users_self'")"
if [[ "$POLICY_COUNT" != "1" ]]; then
  echo "Expected RLS policy was not restored." >&2
  exit 1
fi

HAS_SELECT="$(psql "$TARGET_URL" -X -Atqc "SELECT has_table_privilege('authenticated', 'public.users', 'SELECT')")"
if [[ "$HAS_SELECT" != "t" ]]; then
  echo "Authenticated shadow role lost its source SELECT privilege." >&2
  exit 1
fi

RLS_EMAIL="$(psql "$TARGET_URL" -X -Atq -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
SET LOCAL ROLE authenticated;
SELECT email FROM public.users;
ROLLBACK;
SQL
)"
if [[ "$RLS_EMAIL" != "shadow@example.com" ]]; then
  echo "RLS/auth.uid() aggregate JWT fallback failed: $RLS_EMAIL" >&2
  exit 1
fi

if SOURCE_DATABASE_URL="$SOURCE_URL" \
  TARGET_DATABASE_URL="$TARGET_URL" \
  CONFIRM_SHADOW_RESTORE=NO \
  bash "$ROOT_DIR/scripts/db_sync_from_live.sh" >/dev/null 2>&1; then
  echo "db_sync_from_live.sh should refuse without CONFIRM_SHADOW_RESTORE=YES." >&2
  exit 1
fi

echo "✓ database sync integration test passed"
