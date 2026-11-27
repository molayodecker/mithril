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

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
cat > "$stub_dir/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "api --paginate --slurp repos/example/mithril/git/matching-refs/tags/v")
    printf '[[{"ref":"refs/tags/v0.1.4","object":{"type":"tag","sha":"%s"}}]]\n' "$sha_b"
    ;;
  "api repos/example/mithril/git/ref/tags/v0.1.4")
    printf '{"object":{"type":"tag","sha":"%s"}}\n' "$sha_b"
    ;;
  "api repos/example/mithril/git/tags/$sha_b")
    printf '{"object":{"type":"commit","sha":"%s"}}\n' "$sha_a"
    ;;
  "api repos/example/mithril/git/ref/tags/env/"*)
    printf '{"object":{"type":"commit","sha":"%s"}}\n' "$sha_b"
    ;;
  "api --method PATCH repos/example/mithril/git/refs/tags/env/production -f sha=$sha_a -F force=true" | \
  "api --method PATCH repos/example/mithril/git/refs/tags/env/staging -f sha=$sha_a -F force=true")
    ;;
  *)
    echo "Unexpected GitHub API call: $*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$stub_dir/gh"
export sha_a sha_b
export PATH="$stub_dir:$PATH" GITHUB_REPOSITORY=example/mithril GH_TOKEN=test-token

expect_eq "release creation reuses annotated tag" "v0.1.4" "$(bash "$root/create_release_tag.sh" "$sha_a")"
expect_eq "annotated tag resolves to commit" "$sha_a" "$(python3 "$root/release_tag_lines.py" v0.1.4)"
ENVIRONMENT=production VERSION=v0.1.4 GITHUB_OUTPUT="$stub_dir/output" bash "$root/resolve_deploy_ref.sh"
expect_eq "promotion resolves annotated release" "sha=$sha_a" "$(cat "$stub_dir/output")"
bash "$root/move_env_tag.sh" env/production "$sha_a"
bash "$root/move_env_tag.sh" env/staging "$sha_a"

if [[ "$failures" -ne 0 ]]; then
  echo "$failures release version checks failed." >&2
  exit 1
fi

echo "release version checks passed"
