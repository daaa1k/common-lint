# Common lint

A container GitHub Action that runs static checks for GitHub Actions workflows, commit messages, and Renovate configuration. Each feature can be toggled and is enabled by default.

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

### GitHub token

Pass `GITHUB_TOKEN` (as in the examples) so tools that need API access (for example `zizmor`) can run with the job’s default permissions. Adjust `permissions` if your policies require a narrower scope.

## What runs when

- **GitHub Actions lint** (`actionlint`, `ghalint`, `zizmor`): runs only if the change set includes files under `.github/workflows/` (YAML) or composite action metadata under `.github/actions/**/action.yml`.
- **Renovate check**: runs only if the change set touches `renovate.json`, `renovate.json5`, or `.github/renovate.json`.
- **Commitlint**: runs when enabled; it uses the pull request or push range from the event (or a sensible fallback when history is shallow). Configuration is the bundled Conventional Commits preset, merged with any commitlint config in the repository when present.

## Local development of this action

This repository builds the image from the `Dockerfile` at the repository root. To try it locally:

```bash
docker build -t common-lint .
docker run --rm -e GITHUB_WORKSPACE=/ws -v "$PWD":/ws common-lint
```

Set `GITHUB_EVENT_NAME`, `GITHUB_EVENT_PATH`, and related variables if you need to simulate a specific GitHub event.
