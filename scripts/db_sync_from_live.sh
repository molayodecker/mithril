#!/usr/bin/env bash
set -euo pipefail

# Snapshot the current Instaclean production database (Supabase) and restore it
# into Fly Managed Postgres. This is a refresh, not a DATABASE_BACKEND switch.

if [[ -z "${SOURCE_DATABASE_URL:-}" && "${DATABASE_URL:-}" == postgresql://* ]]; then
  SOURCE_DATABASE_URL="$DATABASE_URL"
fi

: "${SOURCE_DATABASE_URL:?Set SOURCE_DATABASE_URL to the live Instaclean production PostgreSQL URL (session/direct, not transaction pooler)}"
: "${TARGET_DATABASE_URL:?Set TARGET_DATABASE_URL to the dedicated Mithril shadow PostgreSQL database}"

if [[ "${CONFIRM_SHADOW_RESTORE:-}" != "YES" ]]; then
  cat >&2 <<'MSG'
Refusing live production → shadow sync.
Set CONFIRM_SHADOW_RESTORE=YES only after confirming TARGET_DATABASE_URL is the
Mithril shadow database, not production. This overwrites the shadow copy with a
fresh dump from live production.
MSG
  exit 1
fi

if [[ "$SOURCE_DATABASE_URL" == "$TARGET_DATABASE_URL" ]]; then
  echo "SOURCE_DATABASE_URL and TARGET_DATABASE_URL are identical. Refusing sync." >&2
  exit 1
fi

if [[ "$SOURCE_DATABASE_URL" == *":6543/"* || "$SOURCE_DATABASE_URL" == *":6543" ]]; then
  echo "SOURCE_DATABASE_URL looks like a transaction pooler (port 6543). Use session mode (5432) or a direct connection." >&2
  exit 1
fi

if [[ "$SOURCE_DATABASE_URL" == *"flympg.net"* ]]; then
  echo "SOURCE_DATABASE_URL looks like Fly Managed Postgres. Live sync must read Instaclean production, not the shadow cluster." >&2
  exit 1
fi

redact_url() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys
url = sys.argv[1]
parsed = urlparse(url)
host = parsed.hostname or "?"
port = f":{parsed.port}" if parsed.port else ""
user = f"{parsed.username}@" if parsed.username else ""
print(f"{parsed.scheme}://{user}***@{host}{port}{parsed.path}")
PY
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPSHOT_DIR="${DB_SYNC_OUTPUT_DIR:-$ROOT_DIR/.artifacts/db-sync/$STAMP}"
LATEST_FILE="$ROOT_DIR/.artifacts/db-sync/LATEST"

echo "Live production (Supabase) → Mithril Fly Postgres sync"
echo "Source: $(redact_url "$SOURCE_DATABASE_URL")"
echo "Target: $(redact_url "$TARGET_DATABASE_URL")"
echo "This overwrites the Fly database. DATABASE_BACKEND is not changed."
echo

echo "1/3 Snapshot live production..."
SOURCE_DATABASE_URL="$SOURCE_DATABASE_URL" \
  DB_SYNC_OUTPUT_DIR="$SNAPSHOT_DIR" \
  bash "$SCRIPT_DIR/db_sync_snapshot.sh"

mkdir -p "$(dirname "$LATEST_FILE")"
printf '%s\n' "$SNAPSHOT_DIR" > "$LATEST_FILE"
chmod 600 "$LATEST_FILE" 2>/dev/null || true

echo
echo "2/3 Restore snapshot into shadow database..."
SOURCE_DATABASE_URL="$SOURCE_DATABASE_URL" \
  TARGET_DATABASE_URL="$TARGET_DATABASE_URL" \
  SNAPSHOT_DIR="$SNAPSHOT_DIR" \
  CONFIRM_SHADOW_RESTORE=YES \
  bash "$SCRIPT_DIR/db_sync_restore_shadow.sh"

echo
echo "3/3 Verify public row-count parity..."
TARGET_DATABASE_URL="$TARGET_DATABASE_URL" \
  SNAPSHOT_DIR="$SNAPSHOT_DIR" \
  bash "$SCRIPT_DIR/db_sync_verify.sh"

echo
echo "Live production sync complete."
echo "Snapshot: $SNAPSHOT_DIR"
echo "DATABASE_BACKEND was not changed. Mithril still uses whichever backend the flag selects."
