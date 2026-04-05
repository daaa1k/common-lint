#!/usr/bin/env bash
set -euo pipefail

is_true() {
  case "${1:-}" in
    true | True | TRUE | 1 | yes | Yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

cd "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

# Container actions often run as root on a workspace owned by the runner user; Git 2.35+ requires this.
git config --global --add safe.directory "${GITHUB_WORKSPACE}"

# Inputs (kebab-case in action.yml -> INPUT_* with underscores, uppercase)
INPUT_GITHUB_ACTIONS_LINT="${INPUT_GITHUB_ACTIONS_LINT:-true}"
INPUT_COMMITLINT="${INPUT_COMMITLINT:-true}"
INPUT_RENOVATE_CHECK="${INPUT_RENOVATE_CHECK:-true}"

failed=0

# For push events, .before may be missing from the clone after a force-push (orphaned on the server).
# Fall back to the parent of the oldest commit in the payload, then to after^.
resolve_push_from() {
  [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ] || return 1
  [ "${GITHUB_EVENT_NAME:-}" = "push" ] || return 1
  local before after oldest parent
  before=$(jq -r '.before // empty' "$GITHUB_EVENT_PATH")
  after=$(jq -r '.after // empty' "$GITHUB_EVENT_PATH")
  if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ]; then
    return 1
  fi
  if git cat-file -e "${before}^{commit}" 2>/dev/null; then
    printf '%s' "$before"
    return 0
  fi
  oldest=$(jq -r '.commits[0].id // empty' "$GITHUB_EVENT_PATH")
  if [ -n "$oldest" ] && git cat-file -e "${oldest}^{commit}" 2>/dev/null; then
    parent=$(git rev-parse "${oldest}^" 2>/dev/null)
    if [ -n "$parent" ]; then
      printf '%s' "$parent"
      return 0
    fi
  fi
  if git cat-file -e "${after}^{commit}" 2>/dev/null; then
    parent=$(git rev-parse "${after}^" 2>/dev/null)
    if [ -n "$parent" ]; then
      printf '%s' "$parent"
      return 0
    fi
  fi
  return 1
}

get_changed_files() {
  if [ -z "${GITHUB_EVENT_PATH:-}" ] || [ ! -f "$GITHUB_EVENT_PATH" ]; then
    git diff --name-only HEAD~1 HEAD 2>/dev/null || git ls-files
    return
  fi

  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    local base head
    base=$(jq -r '.pull_request.base.sha' "$GITHUB_EVENT_PATH")
    head=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")
    git fetch -q origin "$base" 2>/dev/null || true
    git fetch -q origin "$head" 2>/dev/null || true
    git diff --name-only "$base" "$head"
    return
  fi

  if [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
    local after from
    after=$(jq -r '.after // empty' "$GITHUB_EVENT_PATH")
    if [ -n "$after" ] && from=$(resolve_push_from); then
      git diff --name-only "$from" "$after"
      return
    fi
  fi

  git diff --name-only HEAD~1 HEAD 2>/dev/null || git ls-files
}

matches_github_actions_path() {
  local f="$1"
  if [[ "$f" =~ ^\.github/workflows/.*\.ya?ml$ ]]; then
    return 0
  fi
  if [[ "$f" =~ ^\.github/actions/.+/action\.yml$ ]] || [[ "$f" == .github/actions/action.yml ]]; then
    return 0
  fi
  return 1
}

matches_renovate_path() {
  local f="$1"
  case "$f" in
    renovate.json | renovate.json5 | .github/renovate.json) return 0 ;;
  esac
  return 1
}

should_run_github_actions_lint() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    if matches_github_actions_path "$line"; then
      return 0
    fi
  done
  return 1
}

should_run_renovate_check() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    if matches_renovate_path "$line"; then
      return 0
    fi
  done
  return 1
}

commitlint_default_range() {
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    commitlint --from HEAD~1 --to HEAD
  else
    commitlint --from HEAD --to HEAD
  fi
}

changed_files=$(get_changed_files)

if is_true "$INPUT_GITHUB_ACTIONS_LINT"; then
  if echo "$changed_files" | should_run_github_actions_lint; then
    echo "::group::github-actions-lint (actionlint, ghalint, zizmor)"
    actionlint || failed=1
    ghalint run || failed=1
    zizmor . || failed=1
    echo "::endgroup::"
  else
    echo "Skipping github-actions-lint: no matching files in this change set."
  fi
else
  echo "Skipping github-actions-lint (disabled)."
fi

if is_true "$INPUT_COMMITLINT"; then
  echo "::group::commitlint"
  if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
      from=$(jq -r '.pull_request.base.sha' "$GITHUB_EVENT_PATH")
      to=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")
      git fetch -q origin "$from" 2>/dev/null || true
      git fetch -q origin "$to" 2>/dev/null || true
      commitlint --from "$from" --to "$to" || failed=1
    elif [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
      after=$(jq -r '.after // empty' "$GITHUB_EVENT_PATH")
      if [ -n "$after" ] && from=$(resolve_push_from); then
        commitlint --from "$from" --to "$after" || failed=1
      else
        commitlint_default_range || failed=1
      fi
    else
      commitlint_default_range || failed=1
    fi
  else
    commitlint_default_range || failed=1
  fi
  echo "::endgroup::"
else
  echo "Skipping commitlint (disabled)."
fi

if is_true "$INPUT_RENOVATE_CHECK"; then
  if echo "$changed_files" | should_run_renovate_check; then
    echo "::group::renovate-config-validator"
    args=()
    for f in renovate.json renovate.json5 .github/renovate.json; do
      if [ -f "$f" ]; then
        args+=("$f")
      fi
    done
    if [ "${#args[@]}" -eq 0 ]; then
      echo "No renovate config file found in workspace (unexpected: path matched but file missing)."
      failed=1
    else
      renovate-config-validator "${args[@]}" || failed=1
    fi
    echo "::endgroup::"
  else
    echo "Skipping renovate-check: no matching files in this change set."
  fi
else
  echo "Skipping renovate-check (disabled)."
fi

exit "$failed"
