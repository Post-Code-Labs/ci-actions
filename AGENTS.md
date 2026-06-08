# Repository guide

Shared, reusable GitHub Actions for Post-Code-Labs repositories.

## Include

- Composite actions — one per top-level directory, each with an `action.yml`.
- Reusable workflows under `.github/workflows/`.

## Do not include

- Secrets or credentials — pass tokens in as inputs from the caller.
- Repo-specific or application code.

## Conventions

- Pin every `uses:` to a full commit SHA.
- Bash: `set -euo pipefail`; pass values via `env:`, not inline `${{ }}`.
- Do not mutate global runner state; self-hosted runners persist `$HOME`.
- Land changes via PR; use Conventional Commit titles.
