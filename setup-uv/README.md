# setup-uv

Wraps `astral-sh/setup-uv`, pointing uv's cache at a per-job directory
(`${{ runner.temp }}/uv-cache`). On self-hosted runners several runner instances
share one `$HOME`, so they share uv's default `~/.cache/uv`; when two Python jobs
run concurrently, `uv sync` races extracting the same package into the same path
and fails with `Failed to extract archive` / `No such file or directory`. A
per-job cache dir makes extraction race-free, while `enable-cache` keeps the
cache warm via the GitHub Actions cache service.

## Usage

```yaml
- uses: Post-Code-Labs/ci-actions/setup-uv@<sha> # vX
  # with:
  #   version: 0.9.0          # optional; defaults to project config or latest
  #   python-version: "3.12"  # optional; sets UV_PYTHON
  #   enable-cache: true      # default; restore/save a warm cache (cache service)
  #   cache-suffix: models    # optional; separate caches per monorepo subproject
- run: uv sync --frozen
  working-directory: python/models
```

| Input            | Required | Default                  |
| ---------------- | -------- | ------------------------ |
| `version`        | no       | project config or latest |
| `python-version` | no       | project config           |
| `enable-cache`   | no       | `true`                   |
| `cache-suffix`   | no       | none                     |

The cache lives in `${{ runner.temp }}/uv-cache`, which is unique per job and
wiped afterward, so concurrent jobs on a shared host never extract into the same
path and nothing accumulates in `$HOME`. With `enable-cache: true` the dir is
still restored warm from the GitHub Actions cache service each run.

The inner `astral-sh/setup-uv` pin is kept current by Dependabot, which lists
this directory explicitly in `.github/dependabot.yml`.
