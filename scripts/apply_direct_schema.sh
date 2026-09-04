#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the Mithril PostgreSQL database that should receive Direct tables}"

if [[ "${CONFIRM_DIRECT_SCHEMA:-}" != "YES" ]]; then
  cat >&2 <<'MSG'
Refusing to apply Direct schema.
Set CONFIRM_DIRECT_SCHEMA=YES after confirming TARGET_DATABASE_URL is the
Mithril Fly database (or another dedicated target), not an accidental host.
MSG
  exit 1
fi

if [[ "$TARGET_DATABASE_URL" == *"supabase.co"* || "$TARGET_DATABASE_URL" == *"supabase.com"* ]]; then
  if [[ "${ALLOW_SUPABASE_TARGET:-}" != "YES" ]]; then
    echo "TARGET_DATABASE_URL looks like Supabase. Refusing. instaclean-schema#98 is the Supabase path." >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/../priv/repo/sql/direct/20260903170000_direct_phase1.sql"

if [[ ! -f "$SQL_FILE" ]]; then
  echo "Missing Direct schema file: $SQL_FILE" >&2
  exit 1
fi

psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$SQL_FILE"
echo "Applied Direct Phase 1 schema from $SQL_FILE"
