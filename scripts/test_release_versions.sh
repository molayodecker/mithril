#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sha_a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
sha_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
failures=0

expect_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL $label: expected [$expected] got [$actual]" >&2
    failures=$((failures + 1))
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL $label: command succeeded" >&2
    failures=$((failures + 1))
  fi
}

expect_eq "first release" "v0.1.0" "$(printf '' | "$root/next_release_version.sh" "$sha_a")"
expect_eq "next patch" "v0.1.1" "$(printf 'v0.1.0 %s\n' "$sha_b" | "$root/next_release_version.sh" "$sha_a")"
expect_eq "keep existing" "v0.1.4" "$(
  printf 'v0.1.0 %s\nv0.1.4 %s\n' "$sha_b" "$sha_a" | "$root/next_release_version.sh" "$sha_a"
)"
expect_eq "numeric patch order" "v0.1.11" "$(
  printf 'v0.1.9 %s\nv0.1.10 %s\n' "$sha_b" "$sha_b" | "$root/next_release_version.sh" "$sha_a"
)"
expect_eq "ignore other tags" "v0.1.0" "$(
  printf 'staging/%s %s\nenv/production %s\n' "$sha_a" "$sha_a" "$sha_b" |
    "$root/next_release_version.sh" "$sha_a"
)"

expect_eq "sha target" "sha $sha_a" "$("$root/promotion_target.sh" "$sha_a")"
expect_eq "version target" "version v0.1.4" "$("$root/promotion_target.sh" "v0.1.4")"
expect_eq "staging target" "staging staging/$sha_a" "$("$root/promotion_target.sh" "staging/$sha_a")"
expect_fail "branch target" "$root/promotion_target.sh" main
expect_fail "moving env tag" "$root/promotion_target.sh" env/production
expect_fail "short version" "$root/promotion_target.sh" v1.2
expect_fail "move release script guard" "$root/move_env_tag.sh" v0.1.0 "$sha_a"

python_lines="$(
  python3 "$root/release_tag_lines.py" <<'JSON'
[{"ref":"refs/tags/v0.1.2","object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}]
JSON
)"
expect_eq "tag lines" "v0.1.2 $sha_b" "$python_lines"

if [[ "$failures" -ne 0 ]]; then
  echo "$failures release version checks failed." >&2
  exit 1
fi

echo "release version checks passed"
