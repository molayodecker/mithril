#!/usr/bin/env bash
# Sync STRIPE_SECRET_KEY to one Fly environment.
set -euo pipefail

target="${1:-}"

if [[ -z "${STRIPE_SECRET_KEY:-}" ]]; then
  echo "Export STRIPE_SECRET_KEY before running this script." >&2
  exit 1
fi

case "${target}" in
  staging)
    if [[ ! "${STRIPE_SECRET_KEY}" =~ ^sk_test_ ]]; then
      echo "Staging requires an sk_test_ Stripe key." >&2
      exit 1
    fi
    app="instaclean-mithril-staging"
    ;;
  production | prod)
    if [[ ! "${STRIPE_SECRET_KEY}" =~ ^sk_live_ ]]; then
      echo "Production requires an sk_live_ Stripe key." >&2
      exit 1
    fi
    app="instaclean-mithril"
    ;;
  *)
    echo "Usage: $0 [staging|production]" >&2
    exit 1
    ;;
esac

echo "Setting STRIPE_SECRET_KEY on ${app}..."
fly secrets set "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}" -a "${app}"
echo "Done."
