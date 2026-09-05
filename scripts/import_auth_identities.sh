#!/usr/bin/env bash
set -euo pipefail

# Copies Google / Facebook / phone / Apple identities from live Supabase
# onto Mithril so existing social and SMS users keep the same user id.

: "${SOURCE_DATABASE_URL:?Set SOURCE_DATABASE_URL to live Supabase (session/direct)}"
: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the Mithril Fly database}"

if [[ "${CONFIRM_AUTH_IMPORT:-}" != "YES" ]]; then
  cat >&2 <<'MSG'
Refusing identity import.
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
  i.user_id::text,
  i.provider,
  CASE
    WHEN i.provider = 'phone' THEN
      CASE
        WHEN coalesce(nullif(i.identity_data->>'phone',''), u.phone, p.phone) LIKE '+%'
          THEN coalesce(nullif(i.identity_data->>'phone',''), u.phone, p.phone)
        WHEN coalesce(nullif(i.identity_data->>'phone',''), u.phone, p.phone) ~ '^0[0-9]{9}$'
          THEN '+233' || substr(coalesce(nullif(i.identity_data->>'phone',''), u.phone, p.phone), 2)
        WHEN coalesce(nullif(i.identity_data->>'phone',''), u.phone, p.phone) ~ '^[0-9]{8,15}$'
          THEN '+' || coalesce(nullif(i.identity_data->>'phone',''), u.phone, p.phone)
        ELSE coalesce(nullif(i.identity_data->>'phone',''), u.phone, p.phone)
      END
    ELSE i.provider_id
  END,
  lower(nullif(btrim(coalesce(i.email, i.identity_data->>'email', u.email, p.email)), ''))
FROM auth.identities i
JOIN auth.users u ON u.id = i.user_id
JOIN public.users p ON p.id = i.user_id
WHERE i.provider IN ('google', 'facebook', 'phone', 'apple')
ORDER BY i.user_id, i.provider;
" > "$TMP"

psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 <<SQL
CREATE TEMP TABLE mithril_identity_import (
  user_id uuid NOT NULL,
  provider text NOT NULL,
  provider_subject text NOT NULL,
  email text
);
\\copy mithril_identity_import FROM '$TMP' WITH (FORMAT csv, HEADER true)
INSERT INTO public.mithril_auth_identities (user_id, provider, provider_subject, email)
SELECT user_id, provider, provider_subject, email
FROM mithril_identity_import
WHERE provider_subject IS NOT NULL
  AND btrim(provider_subject) <> ''
  AND EXISTS (SELECT 1 FROM public.users p WHERE p.id = mithril_identity_import.user_id)
ON CONFLICT (provider, provider_subject) DO UPDATE
SET
  user_id = EXCLUDED.user_id,
  email = COALESCE(EXCLUDED.email, public.mithril_auth_identities.email),
  updated_at = now();

UPDATE public.mithril_auth_accounts AS a
SET phone = i.provider_subject, updated_at = now()
FROM public.mithril_auth_identities i
WHERE i.user_id = a.user_id
  AND i.provider = 'phone'
  AND a.phone IS NULL;

INSERT INTO public.mithril_auth_accounts (user_id, email, phone)
SELECT
  i.user_id,
  COALESCE(i.email, i.provider_subject),
  CASE WHEN i.provider = 'phone' THEN i.provider_subject END
FROM public.mithril_auth_identities i
WHERE NOT EXISTS (
  SELECT 1 FROM public.mithril_auth_accounts a WHERE a.user_id = i.user_id
)
ON CONFLICT (user_id) DO NOTHING;
SQL

imported="$(
  psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc \
    "SELECT provider || '=' || count(*) FROM public.mithril_auth_identities GROUP BY provider ORDER BY provider"
)"

echo "Mithril auth identities: $imported"
