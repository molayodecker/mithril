#!/usr/bin/env bash
# Create the immutable vX.Y.Z tag for a commit that just passed staging.
# Prints the tag name. A second run for the same commit prints the existing tag.
set -euo pipefail

deploy_sha="$(printf '%s' "${1:?commit sha required}" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$deploy_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Expected a 40-character commit SHA." >&2
  exit 1
fi
: "${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY}"
: "${GH_TOKEN:?Set GH_TOKEN}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

list_tags() {
  local payload
  if ! payload="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/git/matching-refs/tags/v" 2>/dev/null)"; then
    payload="[]"
  fi
  printf '%s' "$payload" | python3 "$root/release_tag_lines.py"
}

ref_commit() {
  local tag="$1"
  local payload object_sha object_type
  payload="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${tag}")"
  read -r object_sha object_type < <(
    printf '%s' "$payload" |
      python3 -c 'import json,sys; o=json.load(sys.stdin)["object"]; print(o["sha"], o["type"])'
  )
  if [[ "$object_type" == "tag" ]]; then
    payload="$(gh api "repos/${GITHUB_REPOSITORY}/git/tags/${object_sha}")"
    read -r object_sha object_type < <(
      printf '%s' "$payload" |
        python3 -c 'import json,sys; o=json.load(sys.stdin)["object"]; print(o["sha"], o["type"])'
    )
  fi
  printf '%s %s\n' "$(printf '%s' "$object_sha" | tr '[:upper:]' '[:lower:]')" "$object_type"
}

for _ in 1 2 3 4 5; do
  tag="$(list_tags | "$root/next_release_version.sh" "$deploy_sha")"
  if payload="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${tag}" 2>/dev/null)"; then
    read -r existing_sha existing_type < <(ref_commit "$tag")
    if [[ "$existing_type" == "commit" && "$existing_sha" == "$deploy_sha" ]]; then
      echo "Release ${tag} already points at ${deploy_sha}." >&2
      printf '%s\n' "$tag"
      exit 0
    fi
    echo "Release ${tag} points at ${existing_sha}; choosing the next version." >&2
    continue
  fi

  if gh api --method POST "repos/${GITHUB_REPOSITORY}/git/refs" \
    -f ref="refs/tags/${tag}" \
    -f sha="$deploy_sha" >/dev/null; then
    echo "Created release ${tag} -> ${deploy_sha}." >&2
    printf '%s\n' "$tag"
    exit 0
  fi
  echo "Creating ${tag} raced; retrying." >&2
done

echo "Could not create a release tag for ${deploy_sha}." >&2
exit 1
