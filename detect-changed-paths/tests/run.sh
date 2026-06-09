#!/usr/bin/env bash
set -euo pipefail

# Self-contained tests for detect.sh. No framework: each case builds a throwaway
# git repo, runs detect.sh with controlled event env, and asserts the JSON it
# writes to GITHUB_OUTPUT. Needs only git + jq (both present on ubuntu-latest and
# covered by the repo's shellcheck step). Run: bash detect-changed-paths/tests/run.sh
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/detect.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() {
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$1" >&2
}
assert_eq() { # expected actual message
  if [ "$1" = "$2" ]; then ok; else bad "$3 (expected [$1] got [$2])"; fi
}
assert_contains() { # haystack needle message
  if printf '%s' "$1" | grep -qF -- "$2"; then ok; else bad "$3 (missing [$2] in [$1])"; fi
}

# new_repo: create an empty git repo with one baseline commit; echo its path.
new_repo() {
  local d
  d="$(mktemp -d "$WORK/repo.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  git -C "$d" config commit.gpgsign false
  printf 'seed\n' >"$d/base.txt"
  git -C "$d" add -A
  git -C "$d" -c commit.gpgsign=false commit -qm base
  printf '%s' "$d"
}

# commit_files <repo> <message> <file...>: create/append the files and commit;
# echo the new HEAD sha.
commit_files() {
  local repo="$1" msg="$2" f
  shift 2
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    printf 'x\n' >>"$repo/$f"
  done
  git -C "$repo" add -A
  git -C "$repo" -c commit.gpgsign=false commit -qm "$msg"
  git -C "$repo" rev-parse HEAD
}

# detect: run detect.sh in $REPO with the env vars set by the caller. Sets the
# globals OUT (GITHUB_OUTPUT file), LOG (combined stdout/stderr), RC (exit code).
detect() {
  OUT="$(mktemp "$WORK/out.XXXXXX")"
  LOG="$(mktemp "$WORK/log.XXXXXX")"
  RC=0
  (
    cd "$REPO"
    GITHUB_OUTPUT="$OUT" \
      EVENT="${EVENT:-}" PR_BASE="${PR_BASE:-}" PR_HEAD="${PR_HEAD:-}" \
      PUSH_BEFORE="${PUSH_BEFORE:-}" PUSH_AFTER="${PUSH_AFTER:-}" \
      IN_BASE="${IN_BASE:-}" IN_HEAD="${IN_HEAD:-}" \
      LIST_FILES="${LIST_FILES:-none}" FILTERS="${FILTERS:-}" \
      bash "$SCRIPT"
  ) >"$LOG" 2>&1 || RC=$?
}

out_val() { grep "^$1=" "$OUT" | head -1 | cut -d= -f2- || true; }
field() { out_val "$1" | jq -r "$2"; }  # output-key jq-filter -> raw scalar
fieldc() { out_val "$1" | jq -c "$2"; } # output-key jq-filter -> compact JSON

reset() { unset EVENT PR_BASE PR_HEAD PUSH_BEFORE PUSH_AFTER IN_BASE IN_HEAD LIST_FILES FILTERS; }

# --- 1: push diff resolution, recursive/extension globs, root-anchor property ---
reset
REPO="$(new_repo)"
base="$(git -C "$REPO" rev-parse HEAD)"
head="$(commit_files "$REPO" change src/app.ts docs/readme.md apps/web/package.json)"
EVENT=push PUSH_BEFORE="$base" PUSH_AFTER="$head"
FILTERS='{"code":["src/**"],"docs":["**/*.md"],"deps":["package.json"],"infra":["infra/**"]}'
detect
assert_eq 0 "$RC" "1: exit code"
assert_eq true "$(field changes '.code')" "1: code changed"
assert_eq true "$(field changes '.docs')" "1: docs changed"
# root-anchored package.json must NOT match apps/web/package.json
assert_eq false "$(field changes '.deps')" "1: root package.json not matched by nested"
assert_eq false "$(field changes '.infra')" "1: infra untouched"
assert_eq true "$(out_val any)" "1: any"
assert_eq '["code","docs"]' "$(out_val matched)" "1: matched order preserved"
assert_eq 1 "$(field counts '.code')" "1: code count"
assert_eq 0 "$(field counts '.deps')" "1: deps count"

# --- 2: pull_request resolution uses base.sha/head.sha ---
reset
EVENT=pull_request PR_BASE="$base" PR_HEAD="$head"
FILTERS='{"code":["src/**"],"infra":["infra/**"]}'
detect
assert_eq 0 "$RC" "2: exit code"
assert_eq true "$(field changes '.code')" "2: PR code changed"
assert_eq false "$(field changes '.infra')" "2: PR infra untouched"

# --- 3: explicit base/head override the event (avoids the all-changed fallback) ---
reset
EVENT=push PUSH_BEFORE="" PUSH_AFTER="$head" IN_BASE="$base" IN_HEAD="$head"
FILTERS='{"code":["src/**"],"deps":["package.json"]}'
detect
assert_eq 0 "$RC" "3: exit code"
assert_eq true "$(field changes '.code')" "3: explicit refs used"
assert_eq false "$(field changes '.deps')" "3: not the all-changed fallback"

# --- 4: base unavailable -> all-changed fallback via git ls-files ---
reset
EVENT=push PUSH_BEFORE="" PUSH_AFTER="$head"
FILTERS='{"code":["src/**"],"infra":["infra/**"]}'
detect
assert_eq 0 "$RC" "4: exit code"
assert_contains "$(cat "$LOG")" "treating all paths as changed" "4: fallback warning"
assert_eq true "$(field changes '.code')" "4: tracked src matched in fallback"
assert_eq false "$(field changes '.infra')" "4: no infra files even in fallback"

# --- 5a: negation excludes the only changed file -> false ---
reset
REPO="$(new_repo)"
base="$(git -C "$REPO" rev-parse HEAD)"
head="$(commit_files "$REPO" change docs/CHANGELOG.md)"
EVENT=push PUSH_BEFORE="$base" PUSH_AFTER="$head"
FILTERS='{"docs":["docs/**","!docs/CHANGELOG.md"]}'
detect
assert_eq 0 "$RC" "5a: exit code"
assert_eq false "$(field changes '.docs')" "5a: excluded path does not count"

# --- 5b: negation leaves a non-excluded change -> true ---
reset
REPO="$(new_repo)"
base="$(git -C "$REPO" rev-parse HEAD)"
head="$(commit_files "$REPO" change docs/guide.md)"
EVENT=push PUSH_BEFORE="$base" PUSH_AFTER="$head"
FILTERS='{"docs":["docs/**","!docs/CHANGELOG.md"]}'
detect
assert_eq 0 "$RC" "5b: exit code"
assert_eq true "$(field changes '.docs')" "5b: non-excluded path counts"

# --- 6: exclude-only filter is rejected ---
reset
REPO="$(new_repo)"
base="$(git -C "$REPO" rev-parse HEAD)"
head="$(commit_files "$REPO" change docs/x.md)"
EVENT=push PUSH_BEFORE="$base" PUSH_AFTER="$head"
FILTERS='{"bad":["!docs/**"]}'
detect
assert_eq 1 "$RC" "6: exclude-only exits non-zero"
assert_contains "$(cat "$LOG")" "only negated patterns" "6: exclude-only error message"

# --- 7: invalid / empty filters are rejected ---
reset
REPO="$(new_repo)"
EVENT=push PUSH_BEFORE="$(git -C "$REPO" rev-parse HEAD)" PUSH_AFTER="$(git -C "$REPO" rev-parse HEAD)"
FILTERS='[]'
detect
assert_eq 1 "$RC" "7a: array filters rejected"
FILTERS='{}'
detect
assert_eq 1 "$RC" "7b: empty object rejected"

# --- 8: list-files=json populates files; counts reflect multiple files ---
reset
REPO="$(new_repo)"
base="$(git -C "$REPO" rev-parse HEAD)"
head="$(commit_files "$REPO" change src/a.ts src/b.ts)"
EVENT=push PUSH_BEFORE="$base" PUSH_AFTER="$head" LIST_FILES=json
FILTERS='{"code":["src/**"]}'
detect
assert_eq 0 "$RC" "8: exit code"
assert_eq 2 "$(field counts '.code')" "8: two files counted"
assert_eq '["src/a.ts","src/b.ts"]' "$(fieldc files '.code')" "8: files listed"

# --- 9: parity fixture — a docs-only change runs prettier but not webapp ---
reset
REPO="$(new_repo)"
base="$(git -C "$REPO" rev-parse HEAD)"
head="$(commit_files "$REPO" change docs/notes.md)"
EVENT=push PUSH_BEFORE="$base" PUSH_AFTER="$head"
FILTERS='{"webapp":["apps/webapp/**","packages/**","package.json","pnpm-lock.yaml",".github/workflows/ci-ts.yml"],"prettier":["**/*.md","**/*.json","**/*.jsonc","**/*.yml","**/*.yaml","docs/**","apps/**","packages/**",".prettier*"]}'
detect
assert_eq 0 "$RC" "9: exit code"
assert_eq true "$(field changes '.prettier')" "9: prettier runs on docs change"
assert_eq false "$(field changes '.webapp')" "9: webapp skipped on docs change"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
