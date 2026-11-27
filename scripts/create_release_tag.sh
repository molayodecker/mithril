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
  gh api --paginate --slurp "repos/${GITHUB_REPOSITORY}/git/matching-refs/tags/v" |
    python3 "$root/release_tag_lines.py"
}

for _ in 1 2 3 4 5; do
  tag="$(list_tags | "$root/next_release_version.sh" "$deploy_sha")"
  if existing_sha="$(python3 "$root/release_tag_lines.py" "$tag" 2>/dev/null)"; then
    if [[ "$existing_sha" == "$deploy_sha" ]]; then
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
