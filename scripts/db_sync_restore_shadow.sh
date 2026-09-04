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

for command_name in psql pg_restore python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
done

PUBLIC_DUMP="$SNAPSHOT_DIR/public.dump"
AUTH_SCHEMA="$SNAPSHOT_DIR/auth_users_shadow_schema.sql"
AUTH_PROJECTION="$SNAPSHOT_DIR/auth_identity_projection.csv"
SHADOW_ROLES="$SNAPSHOT_DIR/public_shadow_roles.txt"
SHADOW_GRANTS="$SNAPSHOT_DIR/public_shadow_grants.sql"

for required_file in "$PUBLIC_DUMP" "$AUTH_SCHEMA" "$AUTH_PROJECTION" "$SHADOW_ROLES" "$SHADOW_GRANTS"; do
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

echo "Creating extension compatibility wrappers when the target installed them in public..."
"${TARGET_PSQL[@]}" <<'SQL'
CREATE SCHEMA IF NOT EXISTS extensions;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'uuid_generate_v4'
      AND pg_get_function_identity_arguments(p.oid) = ''
  ) THEN
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION extensions.uuid_generate_v4()
      RETURNS uuid
      LANGUAGE sql
      VOLATILE
      AS $body$ SELECT public.uuid_generate_v4() $body$
    $fn$;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'gen_random_uuid'
      AND pg_get_function_identity_arguments(p.oid) = ''
  ) THEN
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION extensions.gen_random_uuid()
      RETURNS uuid
      LANGUAGE sql
      VOLATILE
      AS $body$ SELECT public.gen_random_uuid() $body$
    $fn$;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'gen_random_bytes'
      AND pg_get_function_identity_arguments(p.oid) = 'integer'
  ) THEN
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION extensions.gen_random_bytes(integer)
      RETURNS bytea
      LANGUAGE sql
      VOLATILE
      AS $body$ SELECT public.gen_random_bytes($1) $body$
    $fn$;
  END IF;
END
$$;

DO $$
BEGIN
  EXECUTE 'GRANT USAGE ON SCHEMA extensions TO PUBLIC';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Skipping GRANT USAGE ON SCHEMA extensions: %', SQLERRM;
END
$$;
SQL

echo "Preparing limited application-facing shadow roles..."
while IFS= read -r role_name; do
  [[ -z "$role_name" ]] && continue
  role_exists="$("${TARGET_PSQL[@]}" -v shadow_role="$role_name" -Atq <<'SQL'
SELECT 1 FROM pg_roles WHERE rolname = :'shadow_role';
SQL
)"
  if [[ "$role_exists" == "1" ]]; then
    continue
  fi
  if ! create_output="$("${TARGET_PSQL[@]}" -v shadow_role="$role_name" <<'SQL' 2>&1
SELECT format('CREATE ROLE %I NOLOGIN', :'shadow_role')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'shadow_role'
)
\gexec
SQL
)"; then
    echo "$create_output" >&2
    echo "Cannot CREATE ROLE ${role_name}. On Fly Managed Postgres, create the user with fly mpg users, then re-run restore." >&2
    exit 1
  fi
done < "$SHADOW_ROLES"

echo "Dropping previous public shadow objects (extension-owned objects are left in place)..."
"${TARGET_PSQL[@]}" <<'SQL'
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.relkind, n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('v', 'm', 'r', 'p', 'f', 'S')
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend d
        WHERE d.objid = c.oid
          AND d.deptype = 'e'
      )
    ORDER BY
      CASE c.relkind
        WHEN 'v' THEN 1
        WHEN 'm' THEN 2
        WHEN 'r' THEN 3
        WHEN 'p' THEN 4
        WHEN 'f' THEN 5
        WHEN 'S' THEN 6
      END,
      c.relname
  LOOP
    IF r.relkind = 'v' THEN
      EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', r.nspname, r.relname);
    ELSIF r.relkind = 'm' THEN
      EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I.%I CASCADE', r.nspname, r.relname);
    ELSIF r.relkind IN ('r', 'p') THEN
      EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', r.nspname, r.relname);
    ELSIF r.relkind = 'S' THEN
      EXECUTE format('DROP SEQUENCE IF EXISTS %I.%I CASCADE', r.nspname, r.relname);
    ELSIF r.relkind = 'f' THEN
      EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.%I CASCADE', r.nspname, r.relname);
    END IF;
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend d
        WHERE d.objid = p.oid
          AND d.deptype = 'e'
      )
  LOOP
    EXECUTE format('DROP ROUTINE IF EXISTS %s CASCADE', r.fn);
  END LOOP;

  FOR r IN
    SELECT n.nspname, t.typname
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    LEFT JOIN pg_class c ON c.oid = t.typrelid
    WHERE n.nspname = 'public'
      AND t.typtype IN ('e', 'd', 'r', 'm')
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend d
        WHERE d.objid = t.oid
          AND d.deptype = 'e'
      )
  LOOP
    EXECUTE format('DROP TYPE IF EXISTS %I.%I CASCADE', r.nspname, r.typname);
  END LOOP;
END
$$;
SQL

echo "Preparing sanitized auth compatibility surface..."
"${TARGET_PSQL[@]}" <<'SQL'
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
    DROP SCHEMA auth CASCADE;
  END IF;
END
$$;
CREATE SCHEMA auth;
SQL
"${TARGET_PSQL[@]}" -f "$AUTH_SCHEMA"

"${TARGET_PSQL[@]}" <<'SQL'
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
  )
$$;

CREATE OR REPLACE FUNCTION auth.email()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'
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

# Shadow roles need only the compatibility helpers, not direct access to
# auth.users or a clone of Supabase's internal auth privileges.
while IFS= read -r role_name; do
  [[ -z "$role_name" ]] && continue
  if ! grant_output="$("${TARGET_PSQL[@]}" -v shadow_role="$role_name" <<'SQL' 2>&1
SELECT format('GRANT USAGE ON SCHEMA auth TO %I;', :'shadow_role') \gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO %I;', :'shadow_role') \gexec
SQL
)"; then
    if [[ "$grant_output" == *"MPG system roles cannot be modified"* ]]; then
      echo "Skipping auth grants for ${role_name}: Fly MPG refuses to modify this role."
    else
      echo "$grant_output" >&2
      exit 1
    fi
  fi
done < "$SHADOW_ROLES"

RESTORE_LIST="$SNAPSHOT_DIR/restore.list"
echo "Building Fly-compatible restore list..."
pg_restore -l "$PUBLIC_DUMP" > "$RESTORE_LIST"
python3 - "$RESTORE_LIST" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
skip_substrings = (
    "SCHEMA - public ",
    "COMMENT - SCHEMA public ",
    "TABLE public spatial_ref_sys",
    "TABLE DATA public spatial_ref_sys",
)
kept = []
skipped = []
for line in path.read_text().splitlines(True):
    if line.startswith(";") or not line.strip():
        kept.append(line)
        continue
    if any(fragment in line for fragment in skip_substrings):
        skipped.append(line.strip())
        kept.append("; skipped: " + line)
        continue
    kept.append(line)
path.write_text("".join(kept))
if skipped:
    print("Skipped restore TOC entries:")
    for item in skipped:
        print(f"  {item}")
PY

echo "Restoring full public schema and data..."
# Disable function-body validation only for restore because public SQL still
# contains Supabase-era auth references. Runtime parity tests must exercise the
# restored functions before any cutover.
# Do not use --clean: Fly MPG cannot DROP SCHEMA public, and PostGIS owns
# spatial_ref_sys. Previous public objects were dropped above instead.
PGOPTIONS="${PGOPTIONS:-} -c check_function_bodies=off" \
pg_restore \
  --dbname="$TARGET_DATABASE_URL" \
  --use-list="$RESTORE_LIST" \
  --no-owner \
  --no-privileges \
  --exit-on-error \
  "$PUBLIC_DUMP"

echo "Applying reviewed effective runtime grants for shadow roles..."
if grant_output="$("${TARGET_PSQL[@]}" -f "$SHADOW_GRANTS" 2>&1)"; then
  echo "Applied shadow grants."
elif [[ "$grant_output" == *"MPG system roles cannot be modified"* ]]; then
  echo "Skipped GRANT statements because Fly MPG refuses to modify those roles."
else
  echo "$grant_output" >&2
  exit 1
fi

echo "Restore complete. Run scripts/db_sync_verify.sh before pointing Mithril at this database."
