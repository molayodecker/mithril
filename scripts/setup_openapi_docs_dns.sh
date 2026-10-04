#!/usr/bin/env bash
set -euo pipefail

# Attach OpenAPI documentation hostnames to the existing Mithril Fly apps and print
# the DNS records to create (CNAME to the Fly app hostname).
#
# Run from the mithril repo root after you can run `fly auth whoami`.
#
# Cloudflare: prefer DNS-only (grey cloud) while Fly issues TLS, or add the
# _fly-ownership TXT record from `fly certs setup` when proxied (orange cloud).

PROD_APP="${PROD_APP:-instaclean-mithril}"
STAGING_APP="${STAGING_APP:-instaclean-mithril-staging}"
PROD_DOCS_HOST="${PROD_DOCS_HOST:-openapi.tryinstaclean.com}"
STAGING_DOCS_HOST="${STAGING_DOCS_HOST:-openapi-stage.tryinstaclean.com}"

echo "==> Requesting Fly certificates"
fly certs add "${PROD_DOCS_HOST}" -a "${PROD_APP}"
fly certs setup "${PROD_DOCS_HOST}" -a "${PROD_APP}" || true

fly certs add "${STAGING_DOCS_HOST}" -a "${STAGING_APP}"
fly certs setup "${STAGING_DOCS_HOST}" -a "${STAGING_APP}" || true

echo
echo "==> Certificate status"
fly certs show "${PROD_DOCS_HOST}" -a "${PROD_APP}" || true
fly certs show "${STAGING_DOCS_HOST}" -a "${STAGING_APP}" || true

echo
echo "==> Create these DNS records (Cloudflare or your DNS provider)"
echo
echo "Production docs (${PROD_DOCS_HOST}):"
echo "  Run: fly certs setup ${PROD_DOCS_HOST} -a ${PROD_APP}"
echo "  Typical CNAME: openapi -> <app-id>.${PROD_APP}.fly.dev (see fly certs setup output)"
echo "  Proxy: DNS only recommended until Fly cert is Ready"
echo
echo "Staging docs (${STAGING_DOCS_HOST}):"
echo "  Run: fly certs setup ${STAGING_DOCS_HOST} -a ${STAGING_APP}"
echo "  Typical CNAME: openapi-stage -> <app-id>.${STAGING_APP}.fly.dev (see fly certs setup output)"
echo "  Proxy: DNS only recommended until Fly cert is Ready"
echo
echo "After deploy, verify:"
echo "  curl -sI https://${PROD_DOCS_HOST}/ | head -1"
echo "  curl -sI https://${STAGING_DOCS_HOST}/redoc | head -1"
echo "  curl -s https://api.tryinstaclean.com/openapi.json | head -c 80"
