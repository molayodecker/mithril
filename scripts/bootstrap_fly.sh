#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${FLY_APP_NAME:-instaclean-mithril}"
MPG_NAME="${FLY_MPG_NAME:-instaclean-mithril-pg}"
REGION="${FLY_REGION:-lhr}"
MPG_PLAN="${FLY_MPG_PLAN:-Basic}"
MPG_VOLUME_SIZE="${FLY_MPG_VOLUME_SIZE:-10}"
PG_MAJOR_VERSION="${FLY_PG_MAJOR_VERSION:-17}"

if ! command -v fly >/dev/null 2>&1; then
  echo "flyctl is required. Install it from https://fly.io/docs/flyctl/install/" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to safely inspect Fly JSON output." >&2
  exit 1
fi

if ! fly auth whoami >/dev/null 2>&1; then
  echo "Not authenticated with Fly.io. Run: fly auth login" >&2
  exit 1
fi

resolve_fly_org() {
  if [[ -n "${FLY_ORG:-}" ]]; then
    printf '%s\n' "$FLY_ORG"
    return
  fi

  # `fly mpg list` requires --org when stdout is not a TTY.
  fly orgs list --json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
slugs = []

if isinstance(data, dict):
    slugs = [str(slug) for slug in data.keys()]
elif isinstance(data, list):
    for item in data:
        if isinstance(item, dict):
            slug = item.get("slug") or item.get("Slug")
            if slug:
                slugs.append(str(slug))

if not slugs:
    print("Could not determine Fly organization. Set FLY_ORG.", file=sys.stderr)
    sys.exit(1)

if "personal" in slugs:
    print("personal")
    sys.exit(0)

if len(slugs) == 1:
    print(slugs[0])
    sys.exit(0)

print("Multiple Fly organizations found. Set FLY_ORG to one of: " + ", ".join(slugs), file=sys.stderr)
sys.exit(1)
'
}

FLY_ORG="$(resolve_fly_org)"
ORG_ARGS=(--org "$FLY_ORG")

echo "Fly bootstrap configuration:"
echo "  app:              $APP_NAME"
echo "  managed postgres: $MPG_NAME"
echo "  region:           $REGION"
echo "  plan:             $MPG_PLAN"
echo "  storage:          ${MPG_VOLUME_SIZE} GB"
echo "  postgres:         $PG_MAJOR_VERSION + PostGIS"
echo "  organization:     $FLY_ORG"

echo

if fly status -a "$APP_NAME" >/dev/null 2>&1; then
  echo "✓ Fly app $APP_NAME already exists"
else
  echo "Creating Fly app $APP_NAME..."
  fly apps create "$APP_NAME" "${ORG_ARGS[@]}" --yes
  echo "✓ Created Fly app $APP_NAME"
fi

mpg_list_json="$(fly mpg list "${ORG_ARGS[@]}" --json)"
mpg_exists_status=0
python3 -c '
import json
import sys

target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    print(f"Failed to parse fly mpg list JSON: {exc}", file=sys.stderr)
    sys.exit(2)

def contains_name(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() == "name" and child == target:
                return True
            if contains_name(child):
                return True
    elif isinstance(value, list):
        return any(contains_name(child) for child in value)
    return False

sys.exit(0 if contains_name(data) else 1)
' "$MPG_NAME" <<<"$mpg_list_json" || mpg_exists_status=$?

if [[ "$mpg_exists_status" -eq 0 ]]; then
  echo "✓ Managed Postgres cluster $MPG_NAME already exists"
elif [[ "$mpg_exists_status" -eq 1 ]]; then
  echo "Creating Managed Postgres cluster $MPG_NAME..."
  fly mpg create \
    --name "$MPG_NAME" \
    --region "$REGION" \
    --plan "$MPG_PLAN" \
    --volume-size "$MPG_VOLUME_SIZE" \
    --pg-major-version "$PG_MAJOR_VERSION" \
    --enable-postgis-support \
    "${ORG_ARGS[@]}"
  echo "✓ Created Managed Postgres cluster $MPG_NAME"
else
  echo "Failed to list Managed Postgres clusters for org $FLY_ORG" >&2
  exit "$mpg_exists_status"
fi

echo
echo "Current Fly app:"
fly status -a "$APP_NAME" || true

echo
echo "Managed Postgres clusters:"
fly mpg list "${ORG_ARGS[@]}"

echo
echo "Bootstrap complete."
echo "IMPORTANT: The MPG cluster has NOT been attached to $APP_NAME."
echo "Keep Mithril pointed at Supabase until the R2 restore and parity checks pass."
