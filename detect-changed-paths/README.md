# detect-changed-paths

Detects which caller-defined **filters** a push or pull request touched, so one
workflow can trigger on the union of every job's paths (via the workflow-level
`paths:` filter) and then narrow down which jobs actually run. It replaces the
inline `git diff` + `grep` script that was duplicated across repos.

It uses a plain `git diff` with git glob pathspecs rather than a marketplace
path-filter action, to fit the org's curated-actions policy. Because composite
actions cannot declare dynamically-named outputs, it emits a single `changes`
JSON output (filter name → `"true"`/`"false"`) instead of one boolean per
filter; callers map it into named job outputs with `fromJSON(...)`.

## Usage

Run it in a `changes` job and feed its result into downstream jobs. The calling
job must check out with `fetch-depth: 0` so the base commit is reachable.

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      # fromJSON(...) keeps downstream `== 'true'` comparisons working unchanged.
      quality: ${{ fromJSON(steps.filter.outputs.changes).quality }}
      e2e: ${{ fromJSON(steps.filter.outputs.changes).e2e }}
    steps:
      - uses: actions/checkout@<sha> # v6
        with:
          fetch-depth: 0
      - id: filter
        uses: Post-Code-Labs/ci-actions/detect-changed-paths@<sha> # vX
        with:
          filters: |
            {
              "quality": ["src/**", "package.json", ".github/workflows/ci.yml"],
              "e2e": ["src/**", "e2e/**", "playwright.config.ts"]
            }

  quality:
    needs: changes
    if: ${{ needs.changes.outputs.quality == 'true' }}
    runs-on: ubuntu-latest
    steps: ...
```

## Inputs

| Input               | Required | Default  | Description                                                                                 |
| ------------------- | -------- | -------- | ------------------------------------------------------------------------------------------- |
| `filters`           | yes      | —        | JSON object: filter name → array of git `:(glob)` patterns. A leading `!` marks an exclude. |
| `base`              | no       | `''`     | Explicit base ref/SHA. Overrides the event-derived base.                                    |
| `head`              | no       | `''`     | Explicit head ref/SHA. Overrides the event-derived head.                                    |
| `working-directory` | no       | `'.'`    | Directory to run git in.                                                                    |
| `list-files`        | no       | `'none'` | Set to `json` to also populate the `files` output.                                          |

## Outputs

| Output    | Description                                                                      |
| --------- | -------------------------------------------------------------------------------- |
| `changes` | JSON object, filter name → `"true"`/`"false"`.                                   |
| `any`     | `"true"` if any filter matched, else `"false"`.                                  |
| `matched` | JSON array of the filter names that matched.                                     |
| `counts`  | JSON object, filter name → number of matched files.                              |
| `files`   | JSON object, filter name → array of matched files (only when `list-files=json`). |

## Pattern matching

Patterns are git `:(glob)` pathspecs, evaluated by `git` itself — `**` is
recursive, a bare filename like `package.json` is root-anchored (it does **not**
match `apps/x/package.json`), and a leading `!` excludes. This is close to, but
not identical to, picomatch-style globs used by other path-filter actions:

- **No brace expansion.** Write `["**/*.yml", "**/*.yaml"]`, not `**/*.{yml,yaml}`.
- **Exclude-only filters are rejected.** A filter of only `!`-patterns would
  invert to "everything except", so it must include at least one positive pattern.
- Filter **names** must be `[A-Za-z_][A-Za-z0-9_]*` for `fromJSON(...).name` dot
  access; otherwise use bracket access `fromJSON(...)['my-filter']`.

## Base/head resolution

`base`/`head` inputs win when set. Otherwise: pull requests compare
`pull_request.base.sha`…`pull_request.head.sha`; pushes compare
`event.before`…`sha` (two-dot `git diff <base> <head>`). When the base commit is
unavailable (first push, force-push with a vanished base, or a shallow checkout)
it emits a warning and treats every tracked path as changed — so checkout with
`fetch-depth: 0`.

> `jq` and `git` are required (both present on `ubuntu-latest`, where the
> `changes` job typically runs).
