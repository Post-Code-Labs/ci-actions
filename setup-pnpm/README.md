# setup-pnpm

Wraps `pnpm/action-setup`, installing pnpm into a per-job directory
(`${{ runner.temp }}/setup-pnpm`). On self-hosted runners `$HOME` persists
between jobs, so the default shared `~/setup-pnpm` gets clobbered when jobs run
concurrently; a per-job `dest` avoids that.

Always use this instead of `pnpm/action-setup` directly on shared self-hosted
runners. The default shared `~/setup-pnpm` surfaces as a `[MODULE_NOT_FOUND]`
for `~/setup-pnpm/.../pnpm/dist/worker.js` mid-install when another job
reinstalls the pnpm CLI underneath a running one.

## Usage

```yaml
- uses: Post-Code-Labs/ci-actions/setup-pnpm@<sha> # vX
  # with:
  #   version: 11.3.0   # optional; defaults to package.json packageManager
```

| Input     | Required | Default                         |
| --------- | -------- | ------------------------------- |
| `version` | no       | package.json's `packageManager` |

The inner `pnpm/action-setup` pin is kept current by Dependabot, which lists
this directory explicitly in `.github/dependabot.yml`.
