# sync-cloudflare-secrets

Re-asserts Cloudflare Worker/Pages secrets from the workflow environment on every
deploy. Cloudflare secrets are **write-only** — wrangler and OpenTofu/Terraform
can't read them back — so a one-time `wrangler secret put` is invisible to IaC and
silently drifts from the Actions secret store. This action pushes each named
secret from an env var via `wrangler [pages] secret put` over stdin, so the live
secrets are reconciled to the Actions secrets on each run.

It exists because `cloudflare/wrangler-action`'s `secrets:` input can't cover this
case: it only runs the Workers `secret bulk` command (errors on Pages projects),
requires the Cloudflare secret name to equal the env var name (no renaming), and
throws on an empty value instead of skipping optional secrets. This action adds
renaming, optional secrets, a blank-required guard, and retry under a per-attempt
timeout. It uses `secret put` over stdin rather than `secret bulk` because Pages
`secret bulk` needs a file on disk and has a known hang; `secret put` reads stdin
uniformly for both targets, so no secret value ever touches disk.

## Usage

Set the secret **values** and Cloudflare credentials in the job's `env:` (they're
shared into the action); pass the _config_ via `with:`. Run it **before**
`wrangler pages deploy` — Pages secrets apply to the next deployment.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      # Values are read from the environment by name — never inline.
      AUDIT_GITHUB_APP_CLIENT_SECRET: ${{ secrets.AUDIT_GITHUB_APP_CLIENT_SECRET }}
      RESEND_API_KEY: ${{ secrets.RESEND_API_KEY }}
      OTEL_EXPORTER_OTLP_TOKEN: ${{ secrets.OTEL_EXPORTER_OTLP_TOKEN }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      CLOUDFLARE_ACCOUNT_ID: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
    steps:
      # ... resolve PAGES_PROJECT_NAME, then, before `pages deploy`:
      - uses: Post-Code-Labs/ci-actions/sync-cloudflare-secrets@<sha> # vX
        with:
          target: pages
          project-name: ${{ env.PAGES_PROJECT_NAME }}
          secrets: |
            GITHUB_APP_CLIENT_SECRET=AUDIT_GITHUB_APP_CLIENT_SECRET
            ?RESEND_API_KEY
            ?OTEL_EXPORTER_OTLP_TOKEN
```

For a Worker, use `target: worker` with `name:` / `environment:` instead of
`project-name:`:

```yaml
- uses: Post-Code-Labs/ci-actions/sync-cloudflare-secrets@<sha> # vX
  with:
    target: worker
    name: audit-consumer
    environment: prod
    working-directory: worker # where wrangler resolves config, if name is omitted
    secrets: |
      ANTHROPIC_API_KEY
      GITHUB_APP_PRIVATE_KEY
```

| Input               | Required | Default  | Description                                                         |
| ------------------- | -------- | -------- | ------------------------------------------------------------------- |
| `target`            | yes      | —        | `pages` or `worker`                                                 |
| `secrets`           | yes      | —        | newline secret map (see below)                                      |
| `project-name`      | no       | none     | Pages project (`--project-name`); required when `target=pages`      |
| `name`              | no       | none     | Worker name (`--name`); omit to use the name from `wrangler` config |
| `environment`       | no       | none     | Worker env (`--env`)                                                |
| `working-directory` | no       | `.`      | directory wrangler runs in                                          |
| `wrangler-version`  | no       | `4.97.0` | pinned `npx wrangler@<ver>`                                         |
| `retries`           | no       | `3`      | attempts per secret on transient failure                            |
| `timeout-seconds`   | no       | `60`     | per-attempt timeout guarding a hung wrangler                        |

The action reads `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the
environment (set them in the job `env:`); it fails fast if either is missing.

## Secret map

Each non-blank, non-`#` line of `secrets` is one entry:

| Entry                | Meaning                                                          |
| -------------------- | ---------------------------------------------------------------- |
| `CF_NAME`            | push env var `CF_NAME` as Cloudflare secret `CF_NAME` (required) |
| `CF_NAME=ENV_VAR`    | push env var `ENV_VAR` as Cloudflare secret `CF_NAME` (rename)   |
| `?CF_NAME[=ENV_VAR]` | optional — skipped when the env var is empty/unset               |

Renaming exists because GitHub reserves the `GITHUB_` prefix for Actions secret
names, so a Cloudflare secret like `GITHUB_APP_CLIENT_SECRET` must be sourced from
a differently-named Actions secret. A **required** secret whose env var is empty
fails the action rather than wiping the live value; **optional** secrets are
skipped silently when unset, so you don't have to gate them with `if:`. Each
pushed secret is sent over stdin and masked in logs.

## Behaviour & robustness

- **Idempotent.** Re-asserting the same values every deploy reconciles drift; a
  partial failure self-heals on the next run, and the job fails loudly meanwhile.
- **Retry + timeout.** Each `secret put` is retried up to `retries` times with
  quadratic backoff, each attempt bounded by `timeout-seconds` (via `timeout`),
  so a hung wrangler is killed and retried instead of stalling the deploy.
- **No global state.** `npx`'s cache is pinned under `$RUNNER_TEMP` so concurrent
  jobs on a shared self-hosted runner don't race it and nothing persists in
  `$HOME`.

Wrangler is fetched per-run via `npx wrangler@<wrangler-version>`; there is no
inner `uses:` pin, so this action is not listed in `.github/dependabot.yml` — bump
`wrangler-version` manually when needed.
