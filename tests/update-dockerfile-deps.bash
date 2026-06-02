#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"
MOCK_CURL="${SCRIPT_DIR}/bin/mock-curl"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s' "${haystack}" | grep -F -- "${needle}" >/dev/null 2>&1; then
    printf 'assertion failed: expected output to contain %s\n' "${needle}" >&2
    exit 1
  fi
}

run_success_case() {
  local tmpdir
  local dockerfile
  local mockbin
  local output

  tmpdir="$(mktemp -d)"
  dockerfile="${tmpdir}/Dockerfile"
  mockbin="${tmpdir}/bin"
  mkdir -p "${mockbin}"
  cp "${FIXTURES_DIR}/dockerfiles/base.Dockerfile" "${dockerfile}"
  ln -s "${MOCK_CURL}" "${mockbin}/curl"

  output="$(
    PATH="${mockbin}:$PATH" \
      GITHUB_TOKEN=test-token \
      NOW_EPOCH=1780358400 \
      MINIMUM_RELEASE_AGE_DAYS=3 \
      UPDATE_DOCKERFILE_DEPS_SKIP_GIT_CLEAN_CHECK=1 \
      UPDATE_DOCKERFILE_DEPS_DOCKERFILE="${dockerfile}" \
      MOCK_API_DIR="${FIXTURES_DIR}/api/success" \
      MOCK_API_FALLBACK_DIR="${FIXTURES_DIR}/api/success" \
      bash "${REPO_ROOT}/scripts/update-dockerfile-deps.sh"
  )"

  assert_contains "${output}" "docker/dockerfile: skipped (latest digest is inside the 3-day eligibility window)"
  assert_contains "${output}" "node: updated sha256:8530f76a96d88820d288761f022e318970dda93d01536919fbc16076b7983e63 -> sha256:2222222222222222222222222222222222222222222222222222222222222222"
  assert_contains "${output}" "actionlint: v1.7.12 -> v1.7.13"
  assert_contains "${output}" "ghalint: unchanged (v1.5.5)"
  assert_contains "${output}" "zizmor: v1.24.1 -> v1.24.2"
  assert_contains "${output}" "trivy: unchanged (v0.69.3)"
  assert_contains "${output}" "typos: v1.45.1 -> v1.46.0"
  assert_contains "${output}" "Dockerfile updated."

  grep -F '# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89' "${dockerfile}" >/dev/null
  grep -F 'FROM node:24-bookworm@sha256:2222222222222222222222222222222222222222222222222222222222222222' "${dockerfile}" >/dev/null
  grep -F 'ARG ACTIONLINT_VERSION=v1.7.13' "${dockerfile}" >/dev/null
  grep -F 'ACTIONLINT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; \' "${dockerfile}" >/dev/null
  grep -F 'ARG ZIZMOR_VERSION=v1.24.2' "${dockerfile}" >/dev/null
  grep -F 'ARG TYPOS_VERSION=v1.46.0' "${dockerfile}" >/dev/null
}

run_missing_digest_case() {
  local tmpdir
  local dockerfile
  local mockbin
  local stderr_file

  tmpdir="$(mktemp -d)"
  dockerfile="${tmpdir}/Dockerfile"
  mockbin="${tmpdir}/bin"
  stderr_file="${tmpdir}/stderr.txt"
  mkdir -p "${mockbin}"
  cp "${FIXTURES_DIR}/dockerfiles/base.Dockerfile" "${dockerfile}"
  ln -s "${MOCK_CURL}" "${mockbin}/curl"

  if PATH="${mockbin}:$PATH" \
    GITHUB_TOKEN=test-token \
    NOW_EPOCH=1780358400 \
    MINIMUM_RELEASE_AGE_DAYS=3 \
    UPDATE_DOCKERFILE_DEPS_SKIP_GIT_CLEAN_CHECK=1 \
    UPDATE_DOCKERFILE_DEPS_DOCKERFILE="${dockerfile}" \
    MOCK_API_DIR="${FIXTURES_DIR}/api/missing-digest" \
    MOCK_API_FALLBACK_DIR="${FIXTURES_DIR}/api/success" \
    bash "${REPO_ROOT}/scripts/update-dockerfile-deps.sh" > /dev/null 2> "${stderr_file}"; then
    printf 'assertion failed: missing-digest scenario should fail\n' >&2
    exit 1
  fi

  grep -F 'actionlint: release v1.7.13 asset actionlint_1.7.13_linux_arm64.tar.gz is missing a valid digest' "${stderr_file}" >/dev/null
  cmp -s "${FIXTURES_DIR}/dockerfiles/base.Dockerfile" "${dockerfile}"
}

run_success_case
run_missing_digest_case
printf 'ok\n'
