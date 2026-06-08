# pick-runner

Selects where a heavy job runs: prefers an idle, online self-hosted runner in
the org's homelab runner group, and falls back to GitHub-hosted cloud otherwise.
Use it in a small upfront job and feed its `runs_on` output into a later job's
`runs-on` via `fromJSON`.

## Usage

```yaml
jobs:
  pick-runner:
    runs-on: ubuntu-latest
    outputs:
      runs_on: ${{ steps.pick.outputs.runs_on }}
    steps:
      - id: pick
        uses: Post-Code-Labs/ci-actions/pick-runner@<sha> # vX
        with:
          runner-status-token: ${{ secrets.RUNNER_STATUS_TOKEN }}

  build:
    needs: pick-runner
    runs-on: ${{ fromJSON(needs.pick-runner.outputs.runs_on) }}
    steps: ...
```

| Input                 | Required | Default        |
| --------------------- | -------- | -------------- |
| `runner-status-token` | no       | `''`           |
| `group-name`          | no       | `homelab@121`  |

With no `runner-status-token` (fork PRs, Dependabot), the probe falls back to
cloud, so untrusted code never lands on self-hosted runners.
