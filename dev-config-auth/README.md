# dev-config-auth

Configures git so `pnpm`/`npm` can install the private `Post-Code-Labs/dev-config`
dependency in CI. Writes an ephemeral per-job `GIT_CONFIG_GLOBAL` under
`$RUNNER_TEMP`, so a rotated token always takes effect and nothing persists on
self-hosted runners. Fails fast if the token is empty or cannot read
`dev-config`.

## Usage

```yaml
- uses: Post-Code-Labs/ci-actions/dev-config-auth@<sha> # vX
  with:
    token: ${{ secrets.DEV_CONFIG_TOKEN }}
```

Place after `actions/checkout` and before the install step. The consuming
repo's dependency must reference `github:Post-Code-Labs/dev-config`.

Dependabot secrets are separate from Actions secrets: the same token must also
exist in the Dependabot secret store for Dependabot-triggered runs.
