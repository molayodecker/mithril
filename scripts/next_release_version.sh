#!/usr/bin/env bash
# Print the immutable release tag for a commit.
# stdin: "<tag> <commit-sha>" lines. Tags that are not vMAJOR.MINOR.PATCH are ignored.
# A commit that already has a release tag keeps that tag. Otherwise the next patch
# after the highest existing release is printed. The first release is v0.1.0.
set -euo pipefail

deploy_sha="$(printf '%s' "${1:?commit sha required}" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$deploy_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Expected a 40-character commit SHA." >&2
  exit 1
fi

version_gt() {
  local a1="$1" a2="$2" a3="$3" b1="$4" b2="$5" b3="$6"
  if ((a1 > b1)); then return 0; fi
  if ((a1 < b1)); then return 1; fi
  if ((a2 > b2)); then return 0; fi
  if ((a2 < b2)); then return 1; fi
  ((a3 > b3))
}

belongs=""
bmaj=-1
bmin=-1
bpat=-1
maxtag=""
maxmaj=-1
maxmin=-1
maxpat=-1

while read -r tag tag_sha _; do
  [[ -n "${tag:-}" ]] || continue
  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || continue
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  tag_sha="$(printf '%s' "${tag_sha:-}" | tr '[:upper:]' '[:lower:]')"

  if [[ "$tag_sha" == "$deploy_sha" ]]; then
    if [[ -z "$belongs" ]] || version_gt "$major" "$minor" "$patch" "$bmaj" "$bmin" "$bpat"; then
      belongs="$tag"
      bmaj="$major"
      bmin="$minor"
      bpat="$patch"
    fi
  fi

  if [[ -z "$maxtag" ]] || version_gt "$major" "$minor" "$patch" "$maxmaj" "$maxmin" "$maxpat"; then
    maxtag="$tag"
    maxmaj="$major"
    maxmin="$minor"
    maxpat="$patch"
  fi
done

if [[ -n "$belongs" ]]; then
  printf '%s\n' "$belongs"
  exit 0
fi

if [[ -z "$maxtag" ]]; then
  printf 'v0.1.0\n'
  exit 0
fi

printf 'v%s.%s.%s\n' "$maxmaj" "$maxmin" "$((maxpat + 1))"
