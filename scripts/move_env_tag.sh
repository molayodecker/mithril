#!/usr/bin/env bash
# Point env/staging or env/production at the commit that environment is running.
# Release tags are immutable and cannot be moved by this script.
set -euo pipefail

name="${1:?tag name required}"
sha="$(printf '%s' "${2:?commit sha required}" | tr '[:upper:]' '[:lower:]')"

case "$name" in
  env/staging | env/production) ;;
  *)
    echo "Refusing to move ${name}. Only env/staging and env/production move." >&2
    exit 1
    ;;
esac

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Expected a 40-character commit SHA." >&2
  exit 1
fi
: "${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY}"
: "${GH_TOKEN:?Set GH_TOKEN}"

api_ref="tags/${name}"
if current="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/${api_ref}" 2>/dev/null)"; then
  current_sha="$(
    printf '%s' "$current" |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])' |
      tr '[:upper:]' '[:lower:]'
  )"
  if [[ "$current_sha" == "$sha" ]]; then
    echo "${name} already points at ${sha}." >&2
    exit 0
  fi
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/git/refs/${api_ref}" -f sha="$sha" >/dev/null
  echo "Moved ${name} -> ${sha}." >&2
else
  gh api --method POST "repos/${GITHUB_REPOSITORY}/git/refs" \
    -f ref="refs/tags/${name}" \
    -f sha="$sha" >/dev/null
  echo "Created ${name} -> ${sha}." >&2
fi
