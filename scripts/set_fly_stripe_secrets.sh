#!/usr/bin/env bash
# Sync Stripe checkout secrets to one Fly environment.
set -euo pipefail

target="${1:-}"

if [[ -z "${STRIPE_SECRET_KEY:-}" || -z "${STRIPE_WEBHOOK_SECRET:-}" ]]; then
  echo "Export STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET before running this script." >&2
  exit 1
fi

if [[ ! "${STRIPE_WEBHOOK_SECRET}" =~ ^whsec_ ]]; then
  echo "STRIPE_WEBHOOK_SECRET must start with whsec_." >&2
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

echo "Setting Stripe secrets on ${app}..."
fly secrets set   "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}"   "STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET}"   -a "${app}"
echo "Done."
