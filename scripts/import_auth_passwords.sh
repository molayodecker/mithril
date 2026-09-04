#!/usr/bin/env bash
set -euo pipefail

# Copies bcrypt hashes from live Supabase auth.users into Mithril accounts.
# Does not print emails or hashes.

: "${SOURCE_DATABASE_URL:?Set SOURCE_DATABASE_URL to live Supabase (session/direct)}"
: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the Mithril Fly database}"

if [[ "${CONFIRM_AUTH_IMPORT:-}" != "YES" ]]; then
  cat >&2 <<'MSG'
Refusing password-hash import.
Set CONFIRM_AUTH_IMPORT=YES after confirming SOURCE is live Supabase and
TARGET is the Mithril database.
MSG
  exit 1
fi

if [[ "$SOURCE_DATABASE_URL" == "$TARGET_DATABASE_URL" ]]; then
  echo "SOURCE_DATABASE_URL and TARGET_DATABASE_URL are identical." >&2
  exit 1
fi

if [[ "$TARGET_DATABASE_URL" == *"supabase.co"* || "$TARGET_DATABASE_URL" == *"supabase.com"* ]]; then
  if [[ "${ALLOW_SUPABASE_TARGET:-}" != "YES" ]]; then
    echo "TARGET_DATABASE_URL looks like Supabase. Refusing." >&2
    exit 1
  fi
fi

TMP="$(mktemp)"
chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT

psql "$SOURCE_DATABASE_URL" -X -v ON_ERROR_STOP=1 --csv -c "
SELECT
  u.id::text,
  lower(coalesce(
    nullif(btrim(u.email), ''),
    nullif(btrim(p.email), ''),
    nullif(btrim(u.phone), ''),
    nullif(btrim(p.phone), '')
  )),
  u.encrypted_password
FROM auth.users u
JOIN public.users p ON p.id = u.id
WHERE u.encrypted_password LIKE '\$2%'
  AND coalesce(
    nullif(btrim(u.email), ''),
    nullif(btrim(p.email), ''),
    nullif(btrim(u.phone), ''),
    nullif(btrim(p.phone), '')
  ) IS NOT NULL
ORDER BY u.id;
" > "$TMP"

psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 <<SQL
CREATE TEMP TABLE mithril_auth_import (
  user_id uuid PRIMARY KEY,
  email text NOT NULL,
  password_hash text NOT NULL
);
\\copy mithril_auth_import FROM '$TMP' WITH (FORMAT csv, HEADER true)
INSERT INTO public.mithril_auth_accounts (user_id, email, password_hash)
SELECT user_id, email, password_hash
FROM mithril_auth_import
WHERE EXISTS (SELECT 1 FROM public.users p WHERE p.id = mithril_auth_import.user_id)
ON CONFLICT (user_id) DO UPDATE
SET
  email = EXCLUDED.email,
  password_hash = COALESCE(public.mithril_auth_accounts.password_hash, EXCLUDED.password_hash),
  updated_at = now();
SQL

imported="$(
  psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc \
    "SELECT count(*) FROM public.mithril_auth_accounts WHERE password_hash LIKE '\$2%'"
)"

echo "Mithril auth accounts with bcrypt hashes: $imported"
