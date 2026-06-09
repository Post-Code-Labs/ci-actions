#!/usr/bin/env bash
set -euo pipefail

# Provided by the action's env: block. Assigned here so the contract is explicit
# and shellcheck does not treat them as undefined.
FILTERS="${FILTERS:-}"
LIST_FILES="${LIST_FILES:-none}"
EVENT="${EVENT:-}"
IN_BASE="${IN_BASE:-}"
IN_HEAD="${IN_HEAD:-}"
PR_BASE="${PR_BASE:-}"
PR_HEAD="${PR_HEAD:-}"
PUSH_BEFORE="${PUSH_BEFORE:-}"
PUSH_AFTER="${PUSH_AFTER:-}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

# Resolve base/head. Explicit inputs win; otherwise derive from the event,
# mirroring the inline script this action replaces.
if [ -n "$IN_BASE" ] || [ -n "$IN_HEAD" ]; then
  base="$IN_BASE"
  head="$IN_HEAD"
elif [ "$EVENT" = "pull_request" ] || [ "$EVENT" = "pull_request_target" ]; then
  base="$PR_BASE"
  head="$PR_HEAD"
else
  base="$PUSH_BEFORE"
  head="$PUSH_AFTER"
fi
[ -n "$head" ] || head="HEAD"

# Base unavailable (first push, vanished base, or shallow checkout): reproduce
# the prior behaviour and treat every path as changed via `git ls-files`.
all_changed=0
if [ -z "$base" ] || [ "$base" = "0000000000000000000000000000000000000000" ] \
  || ! git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
  echo "::warning title=detect-changed-paths::Base commit unavailable — treating all paths as changed. Ensure the job checks out with fetch-depth: 0."
  all_changed=1
fi
echo "Comparing base=${base:-<none>} head=$head (event=${EVENT:-<none>}, all_changed=$all_changed)."

# The filters input must be a non-empty JSON object: name -> array of patterns.
if ! jq -e 'type == "object" and (keys | length > 0)' >/dev/null 2>&1 <<<"$FILTERS"; then
  echo "::error title=detect-changed-paths::filters must be a non-empty JSON object mapping filter name -> array of glob patterns."
  exit 1
fi

changes='{}'
counts='{}'
files='{}'
matched='[]'
any='false'

while IFS= read -r name; do
  # Translate this filter's patterns into git glob pathspecs; a leading "!" is an
  # exclude. git does the matching, so we never reimplement glob in bash.
  pathspecs=()
  has_positive=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if [ "${pat#!}" != "$pat" ]; then
      pathspecs+=(":(glob,exclude)${pat#!}")
    else
      pathspecs+=(":(glob)${pat}")
      has_positive=1
    fi
  done < <(jq -r --arg k "$name" '.[$k][]' <<<"$FILTERS")

  # An exclude-only filter inverts under git pathspecs ("everything except X"),
  # the opposite of picomatch — refuse it rather than silently run every job.
  if [ "$has_positive" -eq 0 ]; then
    echo "::error title=detect-changed-paths::filter '$name' has only negated patterns; add at least one positive pattern."
    exit 1
  fi

  if [ "$all_changed" -eq 1 ]; then
    out="$(git ls-files -- "${pathspecs[@]}")"
  else
    out="$(git diff --name-only "$base" "$head" -- "${pathspecs[@]}")"
  fi

  if [ -n "$out" ]; then
    val='true'
    any='true'
    count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    matched="$(jq -c --arg n "$name" '. + [$n]' <<<"$matched")"
  else
    val='false'
    count=0
  fi

  changes="$(jq -c --arg k "$name" --arg v "$val" '. + {($k): $v}' <<<"$changes")"
  counts="$(jq -c --arg k "$name" --argjson c "$count" '. + {($k): $c}' <<<"$counts")"
  if [ "$LIST_FILES" = "json" ]; then
    arr="$(printf '%s' "$out" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
    files="$(jq -c --arg k "$name" --argjson a "$arr" '. + {($k): $a}' <<<"$files")"
  fi
  echo "filter '$name' -> $val ($count files)"
done < <(jq -r 'keys_unsorted[]' <<<"$FILTERS")

{
  echo "changes=$changes"
  echo "any=$any"
  echo "matched=$matched"
  echo "counts=$counts"
  echo "files=$files"
} >>"$GITHUB_OUTPUT"
