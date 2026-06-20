#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"
MOCK_TRIVY="${SCRIPT_DIR}/bin/mock-entrypoint-trivy"
MOCK_CURL="${SCRIPT_DIR}/bin/mock-entrypoint-curl"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s' "${haystack}" | grep -F -- "${needle}" >/dev/null 2>&1; then
    printf 'assertion failed: expected output to contain %s\n' "${needle}" >&2
    exit 1
  fi
}

create_pull_request_workspace() {
  local tmpdir="$1"
  local workspace="${tmpdir}/workspace"
  local event_file="${tmpdir}/event.json"
  local base_sha
  local head_sha

  mkdir -p "$workspace"
  git init -q "$workspace"
  git -C "$workspace" config user.name "Test User"
  git -C "$workspace" config user.email "test@example.com"

  printf 'first\n' > "${workspace}/tracked.txt"
  git -C "$workspace" add tracked.txt
  git -C "$workspace" commit -q -m "feat: base"
  base_sha="$(git -C "$workspace" rev-parse HEAD)"

  printf 'second\n' >> "${workspace}/tracked.txt"
  git -C "$workspace" add tracked.txt
  git -C "$workspace" commit -q -m "feat: head"
  head_sha="$(git -C "$workspace" rev-parse HEAD)"

  printf '{\n  "pull_request": {\n    "number": 42,\n    "base": { "sha": "%s" },\n    "head": { "sha": "%s" }\n  }\n}\n' \
    "$base_sha" "$head_sha" > "$event_file"
}

run_high_severity_warning_case() {
  local tmpdir
  local mockbin
  local comment_payload
  local output
  local comment_body
  local git_config_global

  tmpdir="$(mktemp -d)"
  mockbin="${tmpdir}/bin"
  comment_payload="${tmpdir}/comment-payload.json"
  git_config_global="${tmpdir}/gitconfig"
  mkdir -p "$mockbin"
  ln -s "$MOCK_TRIVY" "${mockbin}/trivy"
  ln -s "$MOCK_CURL" "${mockbin}/curl"
  create_pull_request_workspace "$tmpdir"

  output="$(
    PATH="${mockbin}:$PATH" \
      HOME="${tmpdir}" \
      XDG_CONFIG_HOME="${tmpdir}/.config" \
      GIT_CONFIG_GLOBAL="${git_config_global}" \
      GITHUB_WORKSPACE="${tmpdir}/workspace" \
      GITHUB_EVENT_NAME="pull_request" \
      GITHUB_EVENT_PATH="${tmpdir}/event.json" \
      GITHUB_REPOSITORY="octo/test" \
      GITHUB_SERVER_URL="https://github.com" \
      GITHUB_API_URL="https://api.github.com" \
      GITHUB_RUN_ID="1001" \
      GITHUB_TOKEN="test-token" \
      INPUT_GITHUB_ACTIONS_LINT="false" \
      INPUT_COMMITLINT="false" \
      INPUT_RENOVATE_CHECK="false" \
      INPUT_TYPOS="false" \
      INPUT_VULN_SCAN="true" \
      INPUT_POST_PR_COMMENTS="true" \
      MOCK_TRIVY_MODE="high" \
      MOCK_TRIVY_JSON="${FIXTURES_DIR}/trivy/high-findings.json" \
      MOCK_CURL_CAPTURE_BODY="${comment_payload}" \
      bash "${REPO_ROOT}/entrypoint.sh" 2>&1
  )"

  assert_contains "$output" "::warning::Trivy reported 1 CRITICAL/HIGH finding(s); continuing because vuln-scan is warning-only."
  comment_body="$(jq -r '.body' "${comment_payload}")"
  assert_contains "$comment_body" "**Overall:** **PASSED**"
  assert_contains "$comment_body" "| vuln-scan (Trivy) | ⚠️ **Warning** |"
  assert_contains "$comment_body" "**CRITICAL/HIGH (first 20):**"
}

run_trivy_failure_warning_case() {
  local tmpdir
  local mockbin
  local comment_payload
  local output
  local comment_body
  local git_config_global

  tmpdir="$(mktemp -d)"
  mockbin="${tmpdir}/bin"
  comment_payload="${tmpdir}/comment-payload.json"
  git_config_global="${tmpdir}/gitconfig"
  mkdir -p "$mockbin"
  ln -s "$MOCK_TRIVY" "${mockbin}/trivy"
  ln -s "$MOCK_CURL" "${mockbin}/curl"
  create_pull_request_workspace "$tmpdir"

  output="$(
    PATH="${mockbin}:$PATH" \
      HOME="${tmpdir}" \
      XDG_CONFIG_HOME="${tmpdir}/.config" \
      GIT_CONFIG_GLOBAL="${git_config_global}" \
      GITHUB_WORKSPACE="${tmpdir}/workspace" \
      GITHUB_EVENT_NAME="pull_request" \
      GITHUB_EVENT_PATH="${tmpdir}/event.json" \
      GITHUB_REPOSITORY="octo/test" \
      GITHUB_SERVER_URL="https://github.com" \
      GITHUB_API_URL="https://api.github.com" \
      GITHUB_RUN_ID="1002" \
      GITHUB_TOKEN="test-token" \
      INPUT_GITHUB_ACTIONS_LINT="false" \
      INPUT_COMMITLINT="false" \
      INPUT_RENOVATE_CHECK="false" \
      INPUT_TYPOS="false" \
      INPUT_VULN_SCAN="true" \
      INPUT_POST_PR_COMMENTS="true" \
      MOCK_TRIVY_MODE="fail" \
      MOCK_TRIVY_EXIT_CODE="2" \
      MOCK_CURL_CAPTURE_BODY="${comment_payload}" \
      bash "${REPO_ROOT}/entrypoint.sh" 2>&1
  )"

  assert_contains "$output" "::warning::Trivy exited with code 2; continuing because vuln-scan is warning-only."
  comment_body="$(jq -r '.body' "${comment_payload}")"
  assert_contains "$comment_body" "**Overall:** **PASSED**"
  assert_contains "$comment_body" "| vuln-scan (Trivy) | ⚠️ **Warning** |"
  assert_contains "$comment_body" "trivy exited with code 2"
}

run_high_severity_warning_case
run_trivy_failure_warning_case
printf 'ok\n'
