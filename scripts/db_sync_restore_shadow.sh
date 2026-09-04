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
AUTH_SCHEMA="$SNAPSHOT_DIR/auth_users_shadow_schema.sql"
AUTH_PROJECTION="$SNAPSHOT_DIR/auth_identity_projection.csv"
POLICY_ROLES="$SNAPSHOT_DIR/public_policy_roles.txt"

for required_file in "$PUBLIC_DUMP" "$AUTH_SCHEMA" "$AUTH_PROJECTION" "$POLICY_ROLES"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing snapshot file: $required_file" >&2
    exit 1
  fi
done

if [[ -f "$SNAPSHOT_DIR/SHA256SUMS" ]]; then
  echo "Verifying snapshot checksums..."
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$SNAPSHOT_DIR" && sha256sum -c SHA256SUMS)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$SNAPSHOT_DIR" && shasum -a 256 -c SHA256SUMS)
  else
    echo "Cannot verify SHA256SUMS: install sha256sum or shasum." >&2
    exit 1
  fi
fi

TARGET_PSQL=(psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1)
TARGET_DB_NAME="$("${TARGET_PSQL[@]}" -Atqc 'select current_database()')"
TARGET_SERVER="$("${TARGET_PSQL[@]}" -Atqc "select coalesce(inet_server_addr()::text, 'local') || ':' || inet_server_port()::text")"

echo "Target database: $TARGET_DB_NAME at $TARGET_SERVER"
echo "Snapshot:        $SNAPSHOT_DIR"

if [[ -f "$SNAPSHOT_DIR/required_extensions.sql" ]]; then
  if [[ "${APPLY_CAPTURED_EXTENSIONS:-}" == "YES" ]]; then
    echo "Applying reviewed extension inventory..."
    "${TARGET_PSQL[@]}" -f "$SNAPSHOT_DIR/required_extensions.sql"
  else
    echo "Captured extensions were NOT auto-applied."
    echo "Review $SNAPSHOT_DIR/required_extensions.sql and enable required supported extensions before restore."
  fi
fi

echo "Preparing compatibility roles used by restored RLS policies..."
while IFS= read -r role_name; do
  [[ -z "$role_name" ]] && continue
  "${TARGET_PSQL[@]}" -v policy_role="$role_name" <<'SQL'
SELECT format('CREATE ROLE %I NOLOGIN', :'policy_role')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'policy_role'
)
\gexec
SQL
done < "$POLICY_ROLES"

echo "Preparing sanitized auth compatibility surface..."
"${TARGET_PSQL[@]}" -c 'DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth;'
"${TARGET_PSQL[@]}" -f "$AUTH_SCHEMA"

"${TARGET_PSQL[@]}" <<'SQL'
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
