#!/usr/bin/env bash
set -euo pipefail

# Self-contained tests for sync.sh. No framework: each case runs sync.sh with a
# stubbed `npx` (and `sleep`) on PATH that records argv + stdin and can be
# scripted to fail-then-succeed, then asserts the wrangler command, the piped
# value, exit codes, skips, retries and masking — with no Cloudflare calls.
# Needs only bash + coreutils. Run: bash sync-cloudflare-secrets/tests/run.sh
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sync.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- PATH stubs --------------------------------------------------------------

STUB="$WORK/bin"
mkdir -p "$STUB"

# Fake npx: append "ARGS: ..." and "STDIN: ..." per invocation to NPX_LOG.
# Fails the first FAIL_TIMES invocations (counter in FAIL_COUNTER) to drive retry.
cat >"$STUB/npx" <<'NPX'
#!/usr/bin/env bash
set -euo pipefail
val="$(cat)"
{
  printf 'ARGS: %s\n' "$*"
  printf 'STDIN: %s\n' "$val"
} >>"$NPX_LOG"
if [ "${FAIL_TIMES:-0}" -gt 0 ]; then
  n=0
  [ -s "$FAIL_COUNTER" ] && n="$(cat "$FAIL_COUNTER")"
  if [ "$n" -lt "${FAIL_TIMES}" ]; then
    printf '%s' "$((n + 1))" >"$FAIL_COUNTER"
    echo "fake npx: simulated failure $((n + 1))" >&2
    exit 1
  fi
fi
exit 0
NPX
chmod +x "$STUB/npx"

# Fake sleep: no-op so retry backoff does not slow the suite.
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/sleep"
chmod +x "$STUB/sleep"

# --- harness -----------------------------------------------------------------

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
  if printf '%s' "$1" | grep -qF -- "$2"; then ok; else bad "$3 (missing [$2])"; fi
}
assert_absent() { # haystack needle message
  if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected [$2])"; else ok; fi
}

# sync: run sync.sh with the case env. Sets globals NPX_LOG, LOG, RC.
sync() {
  NPX_LOG="$(mktemp "$WORK/npx.XXXXXX")"
  LOG="$(mktemp "$WORK/log.XXXXXX")"
  : >"$WORK/failctr"
  RC=0
  PATH="$STUB:$PATH" \
    NPX_LOG="$NPX_LOG" FAIL_COUNTER="$WORK/failctr" FAIL_TIMES="${FAIL_TIMES:-0}" \
    RUNNER_TEMP="$WORK/rt" \
    CLOUDFLARE_API_TOKEN="${CF_TOKEN-tkn}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCT-acct}" \
    TARGET="${TARGET:-}" SECRETS_MAP="${SECRETS_MAP:-}" \
    PROJECT_NAME="${PROJECT_NAME:-}" WORKER_NAME="${WORKER_NAME:-}" WORKER_ENV="${WORKER_ENV:-}" \
    WRANGLER_VERSION="${WRANGLER_VERSION:-4.97.0}" \
    RETRIES="${RETRIES:-3}" TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}" \
    GITHUB_APP_CLIENT_SECRET="${GITHUB_APP_CLIENT_SECRET:-}" \
    AUDIT_GITHUB_APP_CLIENT_SECRET="${AUDIT_GITHUB_APP_CLIENT_SECRET:-}" \
    RESEND_API_KEY="${RESEND_API_KEY:-}" \
    OTEL_EXPORTER_OTLP_TOKEN="${OTEL_EXPORTER_OTLP_TOKEN:-}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    bash "$SCRIPT" >"$LOG" 2>&1 || RC=$?
}

reset() {
  unset TARGET SECRETS_MAP PROJECT_NAME WORKER_NAME WORKER_ENV \
    WRANGLER_VERSION RETRIES TIMEOUT_SECONDS FAIL_TIMES CF_TOKEN CF_ACCT \
    GITHUB_APP_CLIENT_SECRET AUDIT_GITHUB_APP_CLIENT_SECRET \
    RESEND_API_KEY OTEL_EXPORTER_OTLP_TOKEN ANTHROPIC_API_KEY
}
argslog() { cat "$NPX_LOG"; }

# --- 1: Pages, rename + optional present + optional absent -------------------
reset
TARGET=pages PROJECT_NAME=post-code-prod
AUDIT_GITHUB_APP_CLIENT_SECRET="clientsecret"
RESEND_API_KEY="resendkey"
# OTEL_EXPORTER_OTLP_TOKEN unset -> skipped
SECRETS_MAP=$'GITHUB_APP_CLIENT_SECRET=AUDIT_GITHUB_APP_CLIENT_SECRET\n?RESEND_API_KEY\n?OTEL_EXPORTER_OTLP_TOKEN'
sync
assert_eq 0 "$RC" "1: exit code"
assert_contains "$(argslog)" "pages secret put GITHUB_APP_CLIENT_SECRET --project-name post-code-prod" "1: rename + project flag"
assert_contains "$(argslog)" "STDIN: clientsecret" "1: renamed value piped via stdin"
assert_contains "$(argslog)" "pages secret put RESEND_API_KEY --project-name post-code-prod" "1: optional-present pushed"
assert_absent "$(argslog)" "OTEL_EXPORTER_OTLP_TOKEN" "1: optional-absent not pushed"
assert_contains "$(cat "$LOG")" "Skipping optional secret OTEL_EXPORTER_OTLP_TOKEN" "1: skip logged"
assert_contains "$(cat "$LOG")" "Synced 2 secret(s) to Cloudflare pages; skipped 1 optional." "1: summary"
assert_contains "$(cat "$LOG")" "::add-mask::clientsecret" "1: value masked"

# --- 2: required secret empty -> refuse, exit 1 ------------------------------
reset
TARGET=pages PROJECT_NAME=p
SECRETS_MAP='GITHUB_APP_CLIENT_SECRET' # value env unset
sync
assert_eq 1 "$RC" "2: exit code"
assert_contains "$(cat "$LOG")" "refusing to push a blank value" "2: blank-guard message"
assert_eq "" "$(argslog)" "2: nothing pushed"

# --- 3: Worker, --name and --env flags ---------------------------------------
reset
TARGET=worker WORKER_NAME=audit-consumer WORKER_ENV=prod
ANTHROPIC_API_KEY="sk-test"
SECRETS_MAP='ANTHROPIC_API_KEY'
sync
assert_eq 0 "$RC" "3: exit code"
assert_contains "$(argslog)" "secret put ANTHROPIC_API_KEY --name audit-consumer --env prod" "3: worker flags"
assert_absent "$(argslog)" "pages secret" "3: not a pages command"

# --- 4: Worker, no name/env -> bare secret put -------------------------------
reset
TARGET=worker
ANTHROPIC_API_KEY="sk-test"
SECRETS_MAP='ANTHROPIC_API_KEY'
sync
assert_eq 0 "$RC" "4: exit code"
assert_contains "$(argslog)" "secret put ANTHROPIC_API_KEY" "4: bare put"
assert_absent "$(argslog)" "--name" "4: no --name"
assert_absent "$(argslog)" "--env" "4: no --env"

# --- 5: retry succeeds after transient failures ------------------------------
reset
TARGET=pages PROJECT_NAME=p RETRIES=3 FAIL_TIMES=2
GITHUB_APP_CLIENT_SECRET="v"
SECRETS_MAP='GITHUB_APP_CLIENT_SECRET'
sync
assert_eq 0 "$RC" "5: eventually succeeds"
assert_eq 3 "$(grep -c '^ARGS:' "$NPX_LOG")" "5: three attempts logged"
assert_contains "$(cat "$LOG")" "retrying in" "5: retry logged"

# --- 6: retry exhausted -> exit 1 --------------------------------------------
reset
TARGET=pages PROJECT_NAME=p RETRIES=2 FAIL_TIMES=5
GITHUB_APP_CLIENT_SECRET="v"
SECRETS_MAP='GITHUB_APP_CLIENT_SECRET'
sync
assert_eq 1 "$RC" "6: exit code"
assert_eq 2 "$(grep -c '^ARGS:' "$NPX_LOG")" "6: stopped at RETRIES attempts"
assert_contains "$(cat "$LOG")" "Failed to set GITHUB_APP_CLIENT_SECRET after 2 attempt(s)" "6: failure message"

# --- 7: invalid target -------------------------------------------------------
reset
TARGET=lambda SECRETS_MAP='X'
sync
assert_eq 1 "$RC" "7: exit code"
assert_contains "$(cat "$LOG")" "target must be 'pages' or 'worker'" "7: target message"

# --- 8: pages without project-name -------------------------------------------
reset
TARGET=pages SECRETS_MAP='X'
sync
assert_eq 1 "$RC" "8: exit code"
assert_contains "$(cat "$LOG")" "project-name is required when target=pages" "8: project-name message"

# --- 9: invalid secret name --------------------------------------------------
reset
TARGET=worker SECRETS_MAP='bad-name!'
sync
assert_eq 1 "$RC" "9: exit code"
assert_contains "$(cat "$LOG")" "invalid secret name 'bad-name!'" "9: invalid name message"

# --- 10: missing Cloudflare credentials --------------------------------------
reset
TARGET=worker SECRETS_MAP='ANTHROPIC_API_KEY' ANTHROPIC_API_KEY=v CF_TOKEN=""
sync
assert_eq 1 "$RC" "10: exit code"
assert_contains "$(cat "$LOG")" "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID must be set" "10: creds message"

# --- 11: comments and blank lines ignored ------------------------------------
reset
TARGET=pages PROJECT_NAME=p
GITHUB_APP_CLIENT_SECRET="v"
SECRETS_MAP=$'# a comment\n\nGITHUB_APP_CLIENT_SECRET\n  # indented comment'
sync
assert_eq 0 "$RC" "11: exit code"
assert_contains "$(cat "$LOG")" "Synced 1 secret(s)" "11: one secret pushed"
assert_eq 1 "$(grep -c '^ARGS:' "$NPX_LOG")" "11: exactly one push"

# --- 12: empty secrets map rejected ------------------------------------------
reset
TARGET=worker SECRETS_MAP=$'\n  \n# only comments\n'
sync
assert_eq 1 "$RC" "12: exit code"
assert_contains "$(cat "$LOG")" "No secrets given" "12: empty-map message"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
