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
SQL_DIR="$SCRIPT_DIR/../priv/repo/sql/direct"

if [[ ! -d "$SQL_DIR" ]]; then
  echo "Missing Direct schema directory: $SQL_DIR" >&2
  exit 1
fi

SQL_FILES="$(find "$SQL_DIR" -maxdepth 1 -type f -name '*.sql' -print | sort)"

if [[ -z "$SQL_FILES" ]]; then
  echo "No Direct schema files found in $SQL_DIR" >&2
  exit 1
fi

count=0
while IFS= read -r sql_file; do
  [[ -n "$sql_file" ]] || continue
  echo "Applying $(basename "$sql_file")"
  psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$sql_file"
  count=$((count + 1))
done <<EOF
$SQL_FILES
EOF

echo "Applied $count Direct schema phase(s) from $SQL_DIR"
