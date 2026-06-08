#!/usr/bin/env bash
set -euo pipefail

if [ -z "${DEV_CONFIG_TOKEN:-}" ]; then
  echo "::error title=dev-config-auth::token input is empty. Dependabot runs read from the Dependabot secret store, not Actions."
  exit 1
fi
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
: "${GITHUB_ENV:?GITHUB_ENV is not set}"

# Per-job git config under RUNNER_TEMP (wiped each job). Replaces ~/.gitconfig
# for this job only, so a rotated token always applies and nothing persists on
# self-hosted runners.
cfg="${RUNNER_TEMP}/dev-config-git.gitconfig"
: >"$cfg"
git config --file "$cfg" \
  "url.https://x-access-token:${DEV_CONFIG_TOKEN}@github.com/Post-Code-Labs/.insteadOf" \
  "git@github.com:Post-Code-Labs/"

# Fail fast if the token cannot read dev-config. Probe from RUNNER_TEMP, not the
# checked-out repo, so actions/checkout's repo-local http.extraheader (the
# workflow GITHUB_TOKEN, which has no dev-config access) does not shadow the
# token here. This mirrors where pnpm clones from.
if ! probe_err="$(cd "$RUNNER_TEMP" && GIT_CONFIG_GLOBAL="$cfg" git ls-remote "git@github.com:Post-Code-Labs/dev-config.git" HEAD 2>&1)"; then
  echo "::error title=dev-config-auth::Cannot authenticate to Post-Code-Labs/dev-config (token expired, revoked, or missing read access)."
  echo "$probe_err"
  exit 1
fi

echo "GIT_CONFIG_GLOBAL=$cfg" >>"$GITHUB_ENV"
echo "Configured ephemeral git auth for Post-Code-Labs/dev-config."
