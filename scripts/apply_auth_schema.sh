#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the Mithril PostgreSQL database}"

if [[ "${CONFIRM_AUTH_SCHEMA:-}" != "YES" ]]; then
  cat >&2 <<'MSG'
Refusing to apply Mithril auth schema.
Set CONFIRM_AUTH_SCHEMA=YES after confirming TARGET_DATABASE_URL.
MSG
  exit 1
fi

if [[ "$TARGET_DATABASE_URL" == *"supabase.co"* || "$TARGET_DATABASE_URL" == *"supabase.com"* ]]; then
  if [[ "${ALLOW_SUPABASE_TARGET:-}" != "YES" ]]; then
    echo "TARGET_DATABASE_URL looks like Supabase. Refusing." >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/../priv/repo/sql/auth/20260904180000_mithril_auth.sql"

psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$SQL_FILE"
echo "Applied Mithril auth schema from $SQL_FILE"
