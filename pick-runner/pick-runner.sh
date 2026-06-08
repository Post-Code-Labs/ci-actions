#!/usr/bin/env bash
set -euo pipefail

# Provided by the action's env: block. Assigned here so the contract is explicit
# and shellcheck doesn't treat them as undefined.
ORG="${ORG:?org input is required}"
GROUP_NAME="${GROUP_NAME:?alternate-runner input is required}"
RUNNER_STATUS_TOKEN="${RUNNER_STATUS_TOKEN:-}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

cloud='"ubuntu-latest"'
selfhosted="$(jq -cn --arg g "$GROUP_NAME" '{group: $g}')"

emit() {
  echo "runs_on=$1" >>"$GITHUB_OUTPUT"
  echo "Selected runner: $1"
}

if [ -z "$RUNNER_STATUS_TOKEN" ]; then
  echo "No runner-status token (fork PR, Dependabot, or secret unset) -> cloud."
  emit "$cloud"
  exit 0
fi

api() {
  curl -fsS \
    -H "Authorization: Bearer $RUNNER_STATUS_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# Resolve the runner group's id by name.
group_id="$(api "https://api.github.com/orgs/$ORG/actions/runner-groups?per_page=100" \
  | jq -r --arg n "$GROUP_NAME" '.runner_groups[] | select(.name == $n) | .id' || true)"

if [ -z "$group_id" ] || [ "$group_id" = "null" ]; then
  echo "Runner group '$GROUP_NAME' not found in '$ORG' (or token lacks access) -> cloud."
  emit "$cloud"
  exit 0
fi

# Count online, idle runners in the group.
idle="$(api "https://api.github.com/orgs/$ORG/actions/runner-groups/$group_id/runners?per_page=100" \
  | jq '[.runners[] | select(.status == "online" and .busy == false)] | length' || echo 0)"

if [ "${idle:-0}" -gt 0 ]; then
  echo "$idle idle runner(s) in '$GROUP_NAME' online -> self-hosted."
  emit "$selfhosted"
else
  echo "No idle runner in '$GROUP_NAME' online -> cloud."
  emit "$cloud"
fi
