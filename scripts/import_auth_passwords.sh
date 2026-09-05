#!/usr/bin/env bash
set -euo pipefail

# Copies bcrypt hashes from live Supabase auth.users into Mithril accounts.
# Does not print emails or hashes. Accounts disabled in Supabase/public.users
# are removed from Mithril auth and have their refresh sessions revoked.

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
TMP_DISABLED="$(mktemp)"
chmod 600 "$TMP" "$TMP_DISABLED"
trap 'rm -f "$TMP" "$TMP_DISABLED"' EXIT

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
  AND u.deleted_at IS NULL
  AND (u.banned_until IS NULL OR u.banned_until <= now())
  AND p.status::text = 'active'
  AND coalesce(
    nullif(btrim(u.email), ''),
    nullif(btrim(p.email), ''),
    nullif(btrim(u.phone), ''),
    nullif(btrim(p.phone), '')
  ) IS NOT NULL
ORDER BY u.id;
" > "$TMP"

psql "$SOURCE_DATABASE_URL" -X -v ON_ERROR_STOP=1 --csv -c "
SELECT u.id::text
FROM auth.users u
JOIN public.users p ON p.id = u.id
WHERE u.encrypted_password LIKE '\$2%'
  AND (
    u.deleted_at IS NOT NULL
    OR u.banned_until > now()
    OR p.status::text <> 'active'
  )
ORDER BY u.id;
" > "$TMP_DISABLED"

psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 <<SQL
CREATE TEMP TABLE mithril_auth_import (
  user_id uuid PRIMARY KEY,
  email text NOT NULL,
  password_hash text NOT NULL
);
CREATE TEMP TABLE mithril_auth_disabled (
  user_id uuid PRIMARY KEY
);
\\copy mithril_auth_import FROM '$TMP' WITH (FORMAT csv, HEADER true)
\\copy mithril_auth_disabled FROM '$TMP_DISABLED' WITH (FORMAT csv, HEADER true)

UPDATE public.mithril_refresh_tokens
SET revoked_at = now()
WHERE revoked_at IS NULL
  AND user_id IN (SELECT user_id FROM mithril_auth_disabled);

DELETE FROM public.mithril_auth_accounts
WHERE user_id IN (SELECT user_id FROM mithril_auth_disabled);

INSERT INTO public.mithril_auth_accounts (user_id, email, phone, password_hash)
SELECT
  user_id,
  CASE WHEN email LIKE '%@%' THEN email ELSE NULL END,
  CASE WHEN email LIKE '%@%' THEN NULL ELSE email END,
  password_hash
FROM mithril_auth_import
WHERE EXISTS (SELECT 1 FROM public.users p WHERE p.id = mithril_auth_import.user_id)
ON CONFLICT (user_id) DO UPDATE
SET
  email = COALESCE(EXCLUDED.email, public.mithril_auth_accounts.email),
  phone = COALESCE(EXCLUDED.phone, public.mithril_auth_accounts.phone),
  password_hash = COALESCE(public.mithril_auth_accounts.password_hash, EXCLUDED.password_hash),
  updated_at = now();
SQL

imported="$(
  psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc \
    "SELECT count(*) FROM public.mithril_auth_accounts WHERE password_hash LIKE '\$2%'"
)"

echo "Mithril auth accounts with bcrypt hashes: $imported"
