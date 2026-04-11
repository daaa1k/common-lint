# Common lint

A container GitHub Action that runs static checks for GitHub Actions workflows, commit messages, and Renovate configuration, plus a Trivy filesystem vulnerability scan. Each feature can be toggled and is enabled by default.

On `pull_request` events, you can optionally post **one new issue comment per workflow run** with a **summary table** (overall pass/fail and per-check status), plus **collapsible** sections for each tool’s output. ANSI color codes are stripped from log text so comments stay readable. Set `post-pr-comments` to `false` if you only want logs in the workflow run.

## Usage in other repositories

Create a workflow file under `.github/workflows/` (for example `.github/workflows/lint.yml`).


```yaml
name: Common Lint

on:
  pull_request:
  push:
    branches:
      - main

permissions:
  contents: read
  pull-requests: write

jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: daaa1k/common-lint@36aff918b71de7babeae1d94e0f59824a8b42410 # v1.0.0
        env:
          GITHUB_TOKEN: ${{ github.token }}
```

### Optional inputs

| Input | Default | Description |
| --- | --- | --- |
| `github-actions-lint` | `true` | Run `actionlint`, `ghalint run`, and `zizmor .` |
| `commitlint` | `true` | Lint commit messages in the commit range for the current event |
| `renovate-check` | `true` | Run `renovate-config-validator` on Renovate config files present in the repo |
| `vuln-scan` | `true` | Run `trivy fs` (vulnerability scanner) on the repository workspace |
| `post-pr-comments` | `true` | On `pull_request`, post one combined comment per run (see below) |

Example with one feature disabled:

```yaml
      - uses: daaa1k/common-lint@36aff918b71de7babeae1d94e0f59824a8b42410 # v1.0.0
        env:
          GITHUB_TOKEN: ${{ github.token }}
        with:
          commitlint: "false"
```

## Requirements in the consuming repository

### Commitlint

- By default this action uses the bundled config (Conventional Commits via `@commitlint/config-conventional`). You do not need a commitlint file in the consuming repository.
- If the repository defines a [commitlint](https://commitlint.js.org/) config (for example `commitlint.config.cjs`, `.commitlintrc.json`, or a `commitlint` field in `package.json`), it is merged with the bundled settings: shared `extends` and `plugins` lists are combined (deduplicated), and other options are merged so your rules and overrides apply on top of the common base.
- Commit messages in the checked range must satisfy the resulting configuration.

### Renovate (optional)

If you use `renovate-check`, keep a supported config file such as `renovate.json` or `renovate.json5` where you expect it.

### Trivy (`vuln-scan`)

- Runs `trivy fs` with the vulnerability scanner on the checked-out workspace. The job **fails** if any finding has severity **CRITICAL** or **HIGH** (other severities are reported but do not fail the job by themselves).
- By default, `node_modules` and `.git` are skipped via Trivy flags. You can add a `.trivyignore` in the repository root for further exclusions (Trivy reads it automatically).
- The first run may download the Trivy vulnerability DB (requires outbound network on the runner).

### Pull request comments (`post-pr-comments`)

- **Required workflow permission:** the workflow file must include `pull-requests: write` (not only `contents: read`). Without it, the API returns HTTP 403 and comments are skipped; the log shows a warning explaining this.
- When the event is `pull_request`, `post-pr-comments` is `true`, and `GITHUB_TOKEN` can create issue comments, the action posts **one issue comment per run** containing: **overall** pass/fail, a **table** of each check (Passed / Failed / Skipped), and **`<details>`** blocks for logs. Each new run adds another comment so the PR keeps history. Plain-text tool logs use fenced \`text\` code blocks with **ANSI escapes removed**; long output is truncated (about **500 lines** or **62,000 characters** per section). The Trivy section uses Markdown (summary, severity counts, and up to 20 CRITICAL/HIGH lines) when the scan succeeds.
- If the token cannot post (for example **pull requests from forks**, where `GITHUB_TOKEN` is read-only on the base repo), the action logs a **warning** and the scan outcome is unchanged.
- Use `permissions: pull-requests: write` (in addition to `contents: read`) so the default `GITHUB_TOKEN` can create comments. If you set `post-pr-comments: false`, you can omit `pull-requests: write` when your policies require the narrowest token.

### GitHub token

Pass `GITHUB_TOKEN` (as in the examples) so tools that need API access (for example `zizmor`) can run with the job’s default permissions. For PR comments, grant **`pull-requests: write`** as shown above. Adjust `permissions` if your policies require a narrower scope.

## What runs when

- **GitHub Actions lint** (`actionlint`, `ghalint`, `zizmor`): runs only if the change set includes files under `.github/workflows/` (YAML) or composite action metadata under `.github/actions/**/action.yml`.
- **Renovate check**: runs only if the change set touches `renovate.json`, `renovate.json5`, or `.github/renovate.json`.
- **Commitlint**: runs when enabled; it uses the pull request or push range from the event (or a sensible fallback when history is shallow). Configuration is the bundled Conventional Commits preset, merged with any commitlint config in the repository when present.
- **Trivy** (`vuln-scan`): runs when enabled; always scans the full workspace (not gated on changed paths).

## Local development of this action

This repository builds the image from the `Dockerfile` at the repository root. To try it locally:

```bash
docker build -t common-lint .
docker run --rm -e GITHUB_WORKSPACE=/ws -v "$PWD":/ws common-lint
```

Set `GITHUB_EVENT_NAME`, `GITHUB_EVENT_PATH`, and related variables if you need to simulate a specific GitHub event.
