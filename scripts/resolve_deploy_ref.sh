#!/usr/bin/env bash
# Resolve a Deploy workflow target to the commit that should be checked out.
# Production requires a version, an immutable staging tag, or a commit SHA.
# Staging uses the workflow commit when no target is given.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
environment="${ENVIRONMENT:?Set ENVIRONMENT to staging or production}"
version="${VERSION:-}"
commit_sha="${COMMIT_SHA:-}"

resolve_tag() {
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
  object_sha="$(printf '%s' "$object_sha" | tr '[:upper:]' '[:lower:]')"
  if [[ "$object_type" != "commit" || ! "$object_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Tag ${tag} does not point at a commit." >&2
    exit 1
  fi
  printf '%s\n' "$object_sha"
}

choose() {
  local target="$1"
  local parsed kind value resolved named
  parsed="$("$root/promotion_target.sh" "$target")"
  kind="${parsed%% *}"
  value="${parsed#* }"
  case "$kind" in
    sha)
      resolved="$value"
      ;;
    version)
      resolved="$(resolve_tag "$value")"
      ;;
    staging)
      named="${value#staging/}"
      resolved="$(resolve_tag "$value")"
      if [[ "$resolved" != "$named" ]]; then
        echo "Tag ${value} points at ${resolved}, not ${named}." >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported promotion target." >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$resolved"
}

resolved=""
if [[ -n "$version" ]]; then
  resolved="$(choose "$version")"
fi
if [[ -n "$commit_sha" ]]; then
  sha_resolved="$(choose "$commit_sha")"
  if [[ -n "$resolved" && "$resolved" != "$sha_resolved" ]]; then
    echo "version resolves to ${resolved} but commit_sha resolves to ${sha_resolved}." >&2
    exit 1
  fi
  resolved="$sha_resolved"
fi

if [[ -z "$resolved" ]]; then
  if [[ "$environment" == "production" ]]; then
    echo "Production promotion needs a version, staging/<sha> tag, or commit SHA." >&2
    exit 1
  fi
  resolved="$(printf '%s' "${GITHUB_SHA:?}" | tr '[:upper:]' '[:lower:]')"
fi

if [[ ! "$resolved" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Resolved deployment commit is not a SHA." >&2
  exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "sha=${resolved}" >> "$GITHUB_OUTPUT"
fi
echo "Resolved deployment commit ${resolved}" >&2
