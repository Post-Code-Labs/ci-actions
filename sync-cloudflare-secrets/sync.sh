#!/usr/bin/env bash
set -euo pipefail

# Re-assert Cloudflare Worker/Pages secrets from the workflow environment.
#
# Config inputs arrive via the action's env: block. Secret *values* and the
# Cloudflare credentials arrive via the caller's job-level env (bidirectionally
# shared into composite-action run steps), and are read here by name — never
# serialised through a YAML/JSON literal — so arbitrary, multiline or
# special-character values stay intact and GitHub's secret masking holds.
#
# Assigned here so the contract is explicit and shellcheck treats them as defined.
TARGET="${TARGET:?target input is required}"
SECRETS_MAP="${SECRETS_MAP:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
WORKER_NAME="${WORKER_NAME:-}"
WORKER_ENV="${WORKER_ENV:-}"
WRANGLER_VERSION="${WRANGLER_VERSION:?wrangler-version input is required}"
RETRIES="${RETRIES:-3}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"

err() { echo "::error title=sync-cloudflare-secrets::$1" >&2; }

# --- preflight ---------------------------------------------------------------

# wrangler reads these from the environment; fail clearly rather than letting
# wrangler emit an opaque auth error per secret.
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  err "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID must be set in the job environment."
  exit 1
fi

case "$RETRIES" in '' | *[!0-9]*) err "retries must be a positive integer, got '$RETRIES'."; exit 1 ;; esac
[ "$RETRIES" -ge 1 ] || { err "retries must be >= 1, got '$RETRIES'."; exit 1; }
case "$TIMEOUT_SECONDS" in '' | *[!0-9]*) err "timeout-seconds must be a positive integer, got '$TIMEOUT_SECONDS'."; exit 1 ;; esac
[ "$TIMEOUT_SECONDS" -ge 1 ] || { err "timeout-seconds must be >= 1, got '$TIMEOUT_SECONDS'."; exit 1; }

# Keep npx's npm cache off the shared self-hosted $HOME — concurrent jobs would
# otherwise race extraction — and skip wrangler's metrics path, which has been
# implicated in hung deploys.
export npm_config_cache="${RUNNER_TEMP}/npm-cache-sync-cf-secrets"
export WRANGLER_SEND_METRICS=false

# Per-attempt timeout wrapper (coreutils). Present on every Linux runner; absent
# on stock macOS, where we degrade to no timeout rather than fail.
timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_cmd="gtimeout"
else
  echo "::warning title=sync-cloudflare-secrets::'timeout' not found; running wrangler without a per-attempt timeout." >&2
fi

# --- wrangler command per target ---------------------------------------------

wrangler=(npx --yes "wrangler@${WRANGLER_VERSION}")
case "$TARGET" in
  pages)
    if [ -z "$PROJECT_NAME" ]; then
      err "project-name is required when target=pages."
      exit 1
    fi
    put=("${wrangler[@]}" pages secret put)
    scope=(--project-name "$PROJECT_NAME")
    ;;
  worker)
    put=("${wrangler[@]}" secret put)
    scope=()
    [ -n "$WORKER_NAME" ] && scope+=(--name "$WORKER_NAME")
    [ -n "$WORKER_ENV" ] && scope+=(--env "$WORKER_ENV")
    ;;
  *)
    err "target must be 'pages' or 'worker', got '$TARGET'."
    exit 1
    ;;
esac

# --- push one secret, with per-attempt timeout and bounded retry -------------

# push_secret <cf_name> <value>: pipe the value to `wrangler [pages] secret put`
# over stdin (no argv exposure). Retry transient failures (network, 5xx, a hung
# wrangler killed by the timeout) up to RETRIES with quadratic backoff. Returns
# non-zero once attempts are exhausted, which aborts the action under `set -e`.
push_secret() {
  local cf_name="$1" value="$2" attempt=1 rc backoff
  local -a cmd
  while :; do
    cmd=()
    [ -n "$timeout_cmd" ] && cmd=("$timeout_cmd" --kill-after=10 "$TIMEOUT_SECONDS")
    cmd+=("${put[@]}" "$cf_name" "${scope[@]}")

    rc=0
    printf '%s' "$value" | "${cmd[@]}" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "Set $cf_name."
      return 0
    fi
    if [ "$attempt" -ge "$RETRIES" ]; then
      err "Failed to set $cf_name after $RETRIES attempt(s) (last exit $rc)."
      return 1
    fi
    backoff=$((attempt * attempt * 2))
    echo "Setting $cf_name failed (exit $rc); retrying in ${backoff}s (attempt $((attempt + 1))/$RETRIES)." >&2
    sleep "$backoff"
    attempt=$((attempt + 1))
  done
}

# --- parse the secrets map and push ------------------------------------------

pushed=0
skipped=0
while IFS= read -r raw; do
  # Trim surrounding whitespace; skip blanks and comments.
  line="${raw#"${raw%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  [ "${line#\#}" != "$line" ] && continue

  # Leading "?" marks the secret optional (skip when its env var is empty).
  optional=false
  if [ "${line#\?}" != "$line" ]; then
    optional=true
    line="${line#\?}"
  fi

  # CF_NAME[=ENV_VAR]: the value is read from ENV_VAR, defaulting to CF_NAME.
  cf_name="${line%%=*}"
  if [ "$line" = "$cf_name" ]; then
    env_var="$cf_name"
  else
    env_var="${line#*=}"
  fi

  case "$cf_name" in
    '' | [0-9]* | *[!A-Za-z0-9_]*)
      err "invalid secret name '$cf_name' (must match [A-Za-z_][A-Za-z0-9_]*)."
      exit 1
      ;;
  esac
  case "$env_var" in
    '' | [0-9]* | *[!A-Za-z0-9_]*)
      err "invalid env var name '$env_var' for secret '$cf_name'."
      exit 1
      ;;
  esac

  value="${!env_var-}"
  if [ -z "$value" ]; then
    if [ "$optional" = true ]; then
      echo "Skipping optional secret $cf_name (env \$$env_var is empty/unset)."
      skipped=$((skipped + 1))
      continue
    fi
    err "Required secret $cf_name is empty (env \$$env_var) — refusing to push a blank value and wipe the live secret."
    exit 1
  fi

  # Defensive: mask the value in logs even if it did not originate from a
  # registered Actions secret (e.g. a value sourced from a var or computed).
  echo "::add-mask::$value"
  push_secret "$cf_name" "$value"
  pushed=$((pushed + 1))
done < <(printf '%s\n' "$SECRETS_MAP")

if [ "$pushed" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  err "No secrets given in the 'secrets' input."
  exit 1
fi

echo "Synced $pushed secret(s) to Cloudflare $TARGET; skipped $skipped optional."
