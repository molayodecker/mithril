#!/usr/bin/env bash
# Classify a production or staging promotion target.
# Prints "sha <sha>", "version <vX.Y.Z>", or "staging staging/<sha>".
set -euo pipefail

target="${1:-}"
if [[ "$target" =~ ^[0-9a-fA-F]{40}$ ]]; then
  printf 'sha %s\n' "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
elif [[ "$target" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'version %s\n' "$target"
elif [[ "$target" =~ ^staging/([0-9a-fA-F]{40})$ ]]; then
  sha="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  printf 'staging staging/%s\n' "$sha"
else
  echo "Promotion target must be a 40-character commit, vX.Y.Z, or staging/<sha>." >&2
  exit 1
fi
