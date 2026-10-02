#!/usr/bin/env bash
# Sync STRIPE_SECRET_KEY to Fly (staging + production Mithril apps).
# Does not print the secret. Use the same value as Supabase edge STRIPE_SECRET_KEY when applicable.
#
# Usage:
#   export STRIPE_SECRET_KEY='sk_test_...'   # staging / test
#   bash scripts/set_fly_stripe_secrets.sh staging
#
#   export STRIPE_SECRET_KEY='sk_live_...'   # production
#   bash scripts/set_fly_stripe_secrets.sh production
#
#   export STRIPE_SECRET_KEY='sk_test_...'
#   bash scripts/set_fly_stripe_secrets.sh both
set -euo pipefail

target="${1:-both}"

if [[ -z "${STRIPE_SECRET_KEY:-}" ]]; then
  echo "Export STRIPE_SECRET_KEY before running this script." >&2
  exit 1
fi

if [[ ! "${STRIPE_SECRET_KEY}" =~ ^sk_(test|live)_ ]]; then
  echo "STRIPE_SECRET_KEY must start with sk_test_ or sk_live_." >&2
  exit 1
fi

set_secret() {
  local app="$1"
  echo "Setting STRIPE_SECRET_KEY on ${app}..."
  fly secrets set "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}" -a "${app}"
}

case "${target}" in
  staging)
    set_secret "instaclean-mithril-staging"
    ;;
  production | prod)
    set_secret "instaclean-mithril"
    ;;
  both)
    set_secret "instaclean-mithril-staging"
    if [[ "${STRIPE_SECRET_KEY}" == sk_live_* ]]; then
      set_secret "instaclean-mithril"
    else
      echo "Skipping production: test key supplied. Re-run with sk_live_ for instaclean-mithril." >&2
    fi
    ;;
  *)
    echo "Usage: $0 [staging|production|both]" >&2
    exit 1
    ;;
esac

echo "Done."
