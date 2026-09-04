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
DB_SYNC_OUTPUT_DIR="$OUT_DIR" "$SCRIPT_DIR/db_sync_inventory.sh" >/dev/null

echo "Creating full public-schema logical snapshot..."
pg_dump "$SOURCE_DATABASE_URL" \
  --format=custom \
  --schema=public \
  --no-owner \
  --no-privileges \
  --file="$OUT_DIR/public.dump"

# This is intentionally not a dump of auth.users. It carries only the identity
# columns needed to satisfy public FK relationships and parity-test current
# account/trust logic. Password hashes, recovery/confirmation tokens, MFA,
# sessions, refresh tokens, and provider identities are not copied.
echo "Exporting sanitized auth identity projection..."
psql "$SOURCE_DATABASE_URL" -X -q -v ON_ERROR_STOP=1 --csv -c "
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
" > "$OUT_DIR/auth_identity_projection.csv"
chmod 600 "$OUT_DIR/auth_identity_projection.csv" 2>/dev/null || true

pg_dump --version > "$OUT_DIR/pg_dump_version.txt"
psql --version > "$OUT_DIR/psql_version.txt"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && sha256sum public.dump auth_identity_projection.csv public_row_counts.csv > SHA256SUMS)
else
  (cd "$OUT_DIR" && shasum -a 256 public.dump auth_identity_projection.csv public_row_counts.csv > SHA256SUMS)
fi

cat > "$OUT_DIR/README.txt" <<TXT
Instaclean production shadow snapshot
Captured: $STAMP

public.dump
  Custom-format pg_dump of the entire public schema and its data.

auth_identity_projection.csv
  Sanitized identity bridge only. No passwords, auth tokens, sessions, MFA,
  provider identities, or recovery/confirmation secrets are included.

This directory may contain production customer data. Keep it private and do not
commit or upload it to GitHub.
TXT

printf '%s\n' "$OUT_DIR"
