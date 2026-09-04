#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the dedicated Mithril shadow PostgreSQL database}"
: "${SNAPSHOT_DIR:?Set SNAPSHOT_DIR to a directory created by scripts/db_sync_snapshot.sh}"

if [[ "${CONFIRM_SHADOW_RESTORE:-}" != "YES" ]]; then
  cat >&2 <<'MSG'
Refusing destructive restore.
Set CONFIRM_SHADOW_RESTORE=YES only after confirming TARGET_DATABASE_URL is the
Mithril shadow database. This script drops/replaces objects from the snapshot.
MSG
  exit 1
fi

if [[ -n "${SOURCE_DATABASE_URL:-}" && "$SOURCE_DATABASE_URL" == "$TARGET_DATABASE_URL" ]]; then
  echo "SOURCE_DATABASE_URL and TARGET_DATABASE_URL are identical. Refusing restore." >&2
  exit 1
fi

if [[ "$TARGET_DATABASE_URL" == *"supabase.co"* || "$TARGET_DATABASE_URL" == *"supabase.com"* ]]; then
  if [[ "${ALLOW_SUPABASE_TARGET:-}" != "YES" ]]; then
    echo "TARGET_DATABASE_URL looks like Supabase. Refusing to overwrite it." >&2
    exit 1
  fi
fi

for command_name in psql pg_restore; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
done

PUBLIC_DUMP="$SNAPSHOT_DIR/public.dump"
AUTH_PROJECTION="$SNAPSHOT_DIR/auth_identity_projection.csv"

for required_file in "$PUBLIC_DUMP" "$AUTH_PROJECTION"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing snapshot file: $required_file" >&2
    exit 1
  fi
done

TARGET_PSQL=(psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1)
TARGET_DB_NAME="$("${TARGET_PSQL[@]}" -Atqc 'select current_database()')"
TARGET_SERVER="$("${TARGET_PSQL[@]}" -Atqc "select coalesce(inet_server_addr()::text, 'local') || ':' || inet_server_port()::text")"

echo "Target database: $TARGET_DB_NAME at $TARGET_SERVER"
echo "Snapshot:        $SNAPSHOT_DIR"

echo "Preparing compatibility roles and sanitized auth bridge..."
"${TARGET_PSQL[@]}" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END
$$;

DROP SCHEMA IF EXISTS auth CASCADE;
CREATE SCHEMA auth;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text,
  phone text,
  created_at timestamptz,
  updated_at timestamptz,
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz,
  last_sign_in_at timestamptz,
  banned_until timestamptz,
  deleted_at timestamptz,
  is_anonymous boolean NOT NULL DEFAULT false,
  aud text,
  role text,
  confirmed_at timestamptz,
  raw_app_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )
$$;

CREATE OR REPLACE FUNCTION auth.email()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )
$$;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  )
$$;
SQL

# psql's \copy is intentionally used so the CSV stays on the operator's machine.
"${TARGET_PSQL[@]}" -c "\copy auth.users(id,email,phone,created_at,updated_at,email_confirmed_at,phone_confirmed_at,last_sign_in_at,banned_until,deleted_at,is_anonymous) FROM '$AUTH_PROJECTION' WITH (FORMAT csv, HEADER true)"

if [[ -f "$SNAPSHOT_DIR/required_extensions.sql" ]]; then
  if [[ "${APPLY_CAPTURED_EXTENSIONS:-}" == "YES" ]]; then
    echo "Applying captured extension inventory..."
    "${TARGET_PSQL[@]}" -f "$SNAPSHOT_DIR/required_extensions.sql"
  else
    echo "Captured extensions were NOT auto-applied."
    echo "Review $SNAPSHOT_DIR/required_extensions.sql and rerun with APPLY_CAPTURED_EXTENSIONS=YES if appropriate."
  fi
fi

echo "Restoring full public schema and data..."
# Disable function-body validation only for restore because public SQL still
# contains Supabase-era auth references. Runtime parity tests must exercise the
# restored functions before any cutover.
PGOPTIONS="${PGOPTIONS:-} -c check_function_bodies=off" \
pg_restore \
  --dbname="$TARGET_DATABASE_URL" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  --exit-on-error \
  "$PUBLIC_DUMP"

echo "Restore complete. Run scripts/db_sync_verify.sh before pointing Mithril at this database."
