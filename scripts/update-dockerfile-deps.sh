#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKERFILE_PATH="${UPDATE_DOCKERFILE_DEPS_DOCKERFILE:-${REPO_ROOT}/Dockerfile}"
MINIMUM_RELEASE_AGE_DAYS="${MINIMUM_RELEASE_AGE_DAYS:-3}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
DOCKER_HUB_API_URL="${DOCKER_HUB_API_URL:-https://hub.docker.com}"
DOCKER_REGISTRY_URL="${DOCKER_REGISTRY_URL:-https://registry-1.docker.io}"
DOCKER_AUTH_URL="${DOCKER_AUTH_URL:-https://auth.docker.io/token}"
SKIP_GIT_CLEAN_CHECK="${UPDATE_DOCKERFILE_DEPS_SKIP_GIT_CLEAN_CHECK:-0}"

STAGED_DOCKERFILE=""
THRESHOLD_EPOCH=""
GITHUB_API_TOKEN=""
SUMMARY_LINES=()
CHANGED=0

GITHUB_RELEASE_DEPS=(
  actionlint
  ghalint
  zizmor
  trivy
  typos
)

cleanup() {
  if [ -n "${STAGED_DOCKERFILE}" ] && [ -f "${STAGED_DOCKERFILE}" ]; then
    rm -f "${STAGED_DOCKERFILE}"
  fi
}

trap cleanup EXIT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

append_summary() {
  SUMMARY_LINES+=("$1")
}

current_epoch() {
  if [ -n "${NOW_EPOCH:-}" ]; then
    printf '%s\n' "${NOW_EPOCH}"
    return
  fi
  date -u '+%s'
}

normalize_iso8601() {
  printf '%s' "$1" \
    | sed -E 's/\.[0-9]+Z$/Z/' \
    | sed -E 's/\.[0-9]+\+00:00$/Z/' \
    | sed -E 's/\+00:00$/Z/'
}

iso8601_to_epoch() {
  local value
  value="$(normalize_iso8601 "$1")"

  if date -u -d "${value}" '+%s' >/dev/null 2>&1; then
    date -u -d "${value}" '+%s'
    return
  fi

  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${value}" '+%s' >/dev/null 2>&1; then
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${value}" '+%s'
    return
  fi

  fail "unsupported timestamp format: ${value}"
}

validate_plain_sha256() {
  [[ "$1" =~ ^[a-f0-9]{64}$ ]]
}

validate_prefixed_sha256() {
  [[ "$1" =~ ^sha256:[a-f0-9]{64}$ ]]
}

strip_sha256_prefix() {
  local value="${1#sha256:}"
  printf '%s\n' "${value}"
}

ensure_positive_integer() {
  [[ "${MINIMUM_RELEASE_AGE_DAYS}" =~ ^[0-9]+$ ]] || fail "MINIMUM_RELEASE_AGE_DAYS must be a non-negative integer"
}

ensure_clean_git_worktree() {
  [ "${SKIP_GIT_CLEAN_CHECK}" = "1" ] && return

  if ! git -C "${REPO_ROOT}" diff --quiet || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    fail "tracked git changes detected; commit or stash them before running this task"
  fi
}

resolve_github_api_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    GITHUB_API_TOKEN="${GITHUB_TOKEN}"
    export GH_TOKEN="${GH_TOKEN:-${GITHUB_API_TOKEN}}"
    return
  fi

  require_command gh
  GITHUB_API_TOKEN="$(gh auth token 2>/dev/null || true)"
  [ -n "${GITHUB_API_TOKEN}" ] || fail "GITHUB_TOKEN is unset and gh auth token failed; run gh auth login or export GITHUB_TOKEN"
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_API_TOKEN}}"
}

github_api_get() {
  local path="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_API_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL}${path}"
}

docker_hub_get() {
  local path="$1"
  curl -fsSL "${DOCKER_HUB_API_URL}${path}"
}

docker_registry_token() {
  local repo="$1"
  local response
  response="$(curl -fsSL "${DOCKER_AUTH_URL}?service=registry.docker.io&scope=repository:${repo}:pull")"
  printf '%s\n' "${response}" | jq -r '.token // .access_token // empty'
}

docker_manifest_digest() {
  local repo="$1"
  local tag="$2"
  local token="$3"
  local headers
  headers="$(
    curl -fsSL \
      -D - \
      -o /dev/null \
      -H "Authorization: Bearer ${token}" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "${DOCKER_REGISTRY_URL}/v2/${repo}/manifests/${tag}"
  )"

  printf '%s\n' "${headers}" \
    | tr -d '\r' \
    | awk 'tolower($1) == "docker-content-digest:" { print $2; exit }'
}

github_repo_for_dep() {
  case "$1" in
    actionlint) printf 'rhysd/actionlint\n' ;;
    ghalint) printf 'suzuki-shunsuke/ghalint\n' ;;
    zizmor) printf 'zizmorcore/zizmor\n' ;;
    trivy) printf 'aquasecurity/trivy\n' ;;
    typos) printf 'crate-ci/typos\n' ;;
    *) fail "unknown dependency: $1" ;;
  esac
}

version_arg_for_dep() {
  case "$1" in
    actionlint) printf 'ACTIONLINT_VERSION\n' ;;
    ghalint) printf 'GHALINT_VERSION\n' ;;
    zizmor) printf 'ZIZMOR_VERSION\n' ;;
    trivy) printf 'TRIVY_VERSION\n' ;;
    typos) printf 'TYPOS_VERSION\n' ;;
    *) fail "unknown dependency: $1" ;;
  esac
}

sha_var_for_dep() {
  case "$1" in
    actionlint) printf 'ACTIONLINT_SHA256\n' ;;
    ghalint) printf 'GHALINT_SHA256\n' ;;
    zizmor) printf 'ZIZMOR_SHA256\n' ;;
    trivy) printf 'TRIVY_SHA256\n' ;;
    typos) printf 'TYPOS_SHA256\n' ;;
    *) fail "unknown dependency: $1" ;;
  esac
}

asset_name_for_dep() {
  local dep="$1"
  local arch="$2"
  local version="$3"
  local plain_version="${version#v}"

  case "${dep}:${arch}" in
    actionlint:amd64) printf 'actionlint_%s_linux_amd64.tar.gz\n' "${plain_version}" ;;
    actionlint:arm64) printf 'actionlint_%s_linux_arm64.tar.gz\n' "${plain_version}" ;;
    ghalint:amd64) printf 'ghalint_%s_linux_amd64.tar.gz\n' "${plain_version}" ;;
    ghalint:arm64) printf 'ghalint_%s_linux_arm64.tar.gz\n' "${plain_version}" ;;
    zizmor:amd64) printf 'zizmor-x86_64-unknown-linux-gnu.tar.gz\n' ;;
    zizmor:arm64) printf 'zizmor-aarch64-unknown-linux-gnu.tar.gz\n' ;;
    trivy:amd64) printf 'trivy_%s_Linux-64bit.tar.gz\n' "${plain_version}" ;;
    trivy:arm64) printf 'trivy_%s_Linux-ARM64.tar.gz\n' "${plain_version}" ;;
    typos:amd64) printf 'typos-%s-x86_64-unknown-linux-musl.tar.gz\n' "${version}" ;;
    typos:arm64) printf 'typos-%s-aarch64-unknown-linux-musl.tar.gz\n' "${version}" ;;
    *) fail "unsupported dependency/arch combination: ${dep}:${arch}" ;;
  esac
}

is_stable_semver_tag() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

extract_arg_value() {
  local file="$1"
  local arg_name="$2"
  awk -F= -v arg_name="${arg_name}" '$1 == "ARG " arg_name { print $2; exit }' "${file}"
}

extract_arch_value() {
  local file="$1"
  local arch="$2"
  local variable="$3"
  awk -v arch="${arch}" -v variable="${variable}" '
    $0 ~ "^[[:space:]]*" arch "\\)[[:space:]]*\\\\?[[:space:]]*$" { in_arch = 1; next }
    in_arch && $0 ~ "^[[:space:]]*;;[[:space:]]*\\\\?[[:space:]]*$" { in_arch = 0 }
    in_arch && $0 ~ "^[[:space:]]*" variable "=" {
      value = $0
      sub(/^[^=]*=/, "", value)
      sub(/;[[:space:]]*\\$/, "", value)
      gsub(/[[:space:]]/, "", value)
      print value
      exit
    }
  ' "${file}"
}

extract_syntax_digest() {
  awk '
    /^# syntax=docker\/dockerfile:1@sha256:/ {
      value = $0
      sub(/^# syntax=docker\/dockerfile:1@/, "", value)
      print value
      exit
    }
  ' "$1"
}

extract_from_digest() {
  awk '
    /^FROM node:24-bookworm@sha256:/ {
      value = $0
      sub(/^FROM node:24-bookworm@/, "", value)
      print value
      exit
    }
  ' "$1"
}

replace_arg_value() {
  local file="$1"
  local arg_name="$2"
  local new_value="$3"
  local tmp
  tmp="$(mktemp)"

  awk -v arg_name="${arg_name}" -v new_value="${new_value}" '
    BEGIN { count = 0 }
    index($0, "ARG " arg_name "=") == 1 {
      print "ARG " arg_name "=" new_value
      count++
      next
    }
    { print }
    END { if (count != 1) exit 1 }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    fail "could not replace ARG ${arg_name} in ${file}"
  }

  mv "${tmp}" "${file}"
}

replace_arch_value() {
  local file="$1"
  local arch="$2"
  local variable="$3"
  local new_value="$4"
  local tmp
  tmp="$(mktemp)"

  awk -v arch="${arch}" -v variable="${variable}" -v new_value="${new_value}" '
    BEGIN { count = 0 }
    $0 ~ "^[[:space:]]*" arch "\\)[[:space:]]*\\\\?[[:space:]]*$" { in_arch = 1; print; next }
    in_arch && $0 ~ "^[[:space:]]*;;[[:space:]]*\\\\?[[:space:]]*$" { in_arch = 0; print; next }
    in_arch && $0 ~ "^[[:space:]]*" variable "=" {
      match($0, /^[[:space:]]*/)
      indent = substr($0, RSTART, RLENGTH)
      printf "%s%s=%s; \\\n", indent, variable, new_value
      count++
      next
    }
    { print }
    END { if (count != 1) exit 1 }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    fail "could not replace ${variable} for ${arch} in ${file}"
  }

  mv "${tmp}" "${file}"
}

replace_syntax_digest() {
  local file="$1"
  local new_digest="$2"
  local tmp
  tmp="$(mktemp)"

  awk -v new_digest="${new_digest}" '
    BEGIN { count = 0 }
    /^# syntax=docker\/dockerfile:1@sha256:/ {
      print "# syntax=docker/dockerfile:1@" new_digest
      count++
      next
    }
    { print }
    END { if (count != 1) exit 1 }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    fail "could not replace Dockerfile syntax digest"
  }

  mv "${tmp}" "${file}"
}

replace_from_digest() {
  local file="$1"
  local new_digest="$2"
  local tmp
  tmp="$(mktemp)"

  awk -v new_digest="${new_digest}" '
    BEGIN { count = 0 }
    /^FROM node:24-bookworm@sha256:/ {
      print "FROM node:24-bookworm@" new_digest
      count++
      next
    }
    { print }
    END { if (count != 1) exit 1 }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    fail "could not replace node base image digest"
  }

  mv "${tmp}" "${file}"
}

resolve_github_release_candidate() {
  local dep="$1"
  local repo
  local releases_json
  local saw_stable=0
  local saw_release_inside_window=0

  repo="$(github_repo_for_dep "${dep}")"
  releases_json="$(github_api_get "/repos/${repo}/releases?per_page=100")"

  while IFS= read -r release; do
    [ -n "${release}" ] || continue

    local tag_name
    local draft
    local prerelease
    local published_at
    local published_epoch
    local amd64_asset_name
    local arm64_asset_name
    local amd64_asset
    local arm64_asset
    local amd64_digest
    local arm64_digest
    local amd64_updated_at
    local arm64_updated_at
    local effective_epoch
    local amd64_updated_epoch
    local arm64_updated_epoch

    tag_name="$(printf '%s' "${release}" | jq -r '.tag_name // empty')"
    draft="$(printf '%s' "${release}" | jq -r '.draft // false')"
    prerelease="$(printf '%s' "${release}" | jq -r '.prerelease // false')"
    published_at="$(printf '%s' "${release}" | jq -r '.published_at // empty')"

    [ "${draft}" = "false" ] || continue
    [ "${prerelease}" = "false" ] || continue
    is_stable_semver_tag "${tag_name}" || continue
    [ -n "${published_at}" ] || fail "${dep}: release ${tag_name} is missing published_at"

    saw_stable=1
    published_epoch="$(iso8601_to_epoch "${published_at}")"
    if [ "${published_epoch}" -gt "${THRESHOLD_EPOCH}" ]; then
      saw_release_inside_window=1
      continue
    fi

    amd64_asset_name="$(asset_name_for_dep "${dep}" amd64 "${tag_name}")"
    arm64_asset_name="$(asset_name_for_dep "${dep}" arm64 "${tag_name}")"
    amd64_asset="$(printf '%s' "${release}" | jq -c --arg name "${amd64_asset_name}" '.assets[]? | select(.name == $name)' | head -n 1)"
    arm64_asset="$(printf '%s' "${release}" | jq -c --arg name "${arm64_asset_name}" '.assets[]? | select(.name == $name)' | head -n 1)"

    [ -n "${amd64_asset}" ] || fail "${dep}: release ${tag_name} is missing asset ${amd64_asset_name}"
    [ -n "${arm64_asset}" ] || fail "${dep}: release ${tag_name} is missing asset ${arm64_asset_name}"

    amd64_digest="$(printf '%s' "${amd64_asset}" | jq -r '.digest // empty')"
    arm64_digest="$(printf '%s' "${arm64_asset}" | jq -r '.digest // empty')"
    amd64_updated_at="$(printf '%s' "${amd64_asset}" | jq -r '.updated_at // empty')"
    arm64_updated_at="$(printf '%s' "${arm64_asset}" | jq -r '.updated_at // empty')"

    validate_prefixed_sha256 "${amd64_digest}" || fail "${dep}: release ${tag_name} asset ${amd64_asset_name} is missing a valid digest"
    validate_prefixed_sha256 "${arm64_digest}" || fail "${dep}: release ${tag_name} asset ${arm64_asset_name} is missing a valid digest"
    [ -n "${amd64_updated_at}" ] || fail "${dep}: release ${tag_name} asset ${amd64_asset_name} is missing updated_at"
    [ -n "${arm64_updated_at}" ] || fail "${dep}: release ${tag_name} asset ${arm64_asset_name} is missing updated_at"

    amd64_updated_epoch="$(iso8601_to_epoch "${amd64_updated_at}")"
    arm64_updated_epoch="$(iso8601_to_epoch "${arm64_updated_at}")"

    effective_epoch="${published_epoch}"
    [ "${amd64_updated_epoch}" -gt "${effective_epoch}" ] && effective_epoch="${amd64_updated_epoch}"
    [ "${arm64_updated_epoch}" -gt "${effective_epoch}" ] && effective_epoch="${arm64_updated_epoch}"

    if [ "${effective_epoch}" -gt "${THRESHOLD_EPOCH}" ]; then
      saw_release_inside_window=1
      continue
    fi

    printf '%s\t%s\t%s\n' \
      "${tag_name}" \
      "$(strip_sha256_prefix "${amd64_digest}")" \
      "$(strip_sha256_prefix "${arm64_digest}")"
    return 0
  done < <(printf '%s' "${releases_json}" | jq -c '.[]')

  if [ "${saw_stable}" -eq 0 ]; then
    fail "${dep}: no stable semver releases found"
  fi

  if [ "${saw_release_inside_window}" -eq 1 ]; then
    return 2
  fi

  fail "${dep}: no eligible stable release found"
}

resolve_docker_tag_candidate() {
  local label="$1"
  local namespace="$2"
  local repository="$3"
  local pull_repo="$4"
  local tag="$5"
  local tag_json
  local last_updated
  local last_updated_epoch
  local registry_token
  local manifest_digest

  tag_json="$(docker_hub_get "/v2/namespaces/${namespace}/repositories/${repository}/tags/${tag}")"
  last_updated="$(printf '%s' "${tag_json}" | jq -r '.last_updated // empty')"
  [ -n "${last_updated}" ] || fail "${label}: Docker Hub tag metadata is missing last_updated"

  last_updated_epoch="$(iso8601_to_epoch "${last_updated}")"
  if [ "${last_updated_epoch}" -gt "${THRESHOLD_EPOCH}" ]; then
    return 2
  fi

  registry_token="$(docker_registry_token "${pull_repo}")"
  [ -n "${registry_token}" ] || fail "${label}: failed to resolve Docker registry token"

  manifest_digest="$(docker_manifest_digest "${pull_repo}" "${tag}" "${registry_token}")"
  validate_prefixed_sha256 "${manifest_digest}" || fail "${label}: registry did not return a valid manifest digest"

  printf '%s\n' "${manifest_digest}"
}

assert_non_empty() {
  [ -n "$2" ] || fail "$1"
}

process_docker_syntax() {
  local current_digest
  local candidate_digest
  local status

  current_digest="$(extract_syntax_digest "${DOCKERFILE_PATH}")"
  assert_non_empty "could not parse current Dockerfile syntax digest" "${current_digest}"
  validate_prefixed_sha256 "${current_digest}" || fail "current Dockerfile syntax digest is invalid"

  status=0
  candidate_digest="$(resolve_docker_tag_candidate "docker/dockerfile:1" docker dockerfile docker/dockerfile 1)" || status=$?
  if [ "${status}" -eq 0 ]; then
    if [ "${candidate_digest}" = "${current_digest}" ]; then
      append_summary "docker/dockerfile: unchanged (${candidate_digest})"
      return
    fi

    replace_syntax_digest "${STAGED_DOCKERFILE}" "${candidate_digest}"
    CHANGED=1
    append_summary "docker/dockerfile: updated ${current_digest} -> ${candidate_digest}"
    return
  fi

  case "${status}" in
    2) append_summary "docker/dockerfile: skipped (latest digest is inside the ${MINIMUM_RELEASE_AGE_DAYS}-day eligibility window)" ;;
    *) fail "docker/dockerfile: unexpected resolution failure" ;;
  esac
}

process_node_base_image() {
  local current_digest
  local candidate_digest
  local status

  current_digest="$(extract_from_digest "${DOCKERFILE_PATH}")"
  assert_non_empty "could not parse current node base image digest" "${current_digest}"
  validate_prefixed_sha256 "${current_digest}" || fail "current node base image digest is invalid"

  status=0
  candidate_digest="$(resolve_docker_tag_candidate "node:24-bookworm" library node library/node 24-bookworm)" || status=$?
  if [ "${status}" -eq 0 ]; then
    if [ "${candidate_digest}" = "${current_digest}" ]; then
      append_summary "node: unchanged (${candidate_digest})"
      return
    fi

    replace_from_digest "${STAGED_DOCKERFILE}" "${candidate_digest}"
    CHANGED=1
    append_summary "node: updated ${current_digest} -> ${candidate_digest}"
    return
  fi

  case "${status}" in
    2) append_summary "node: skipped (latest digest is inside the ${MINIMUM_RELEASE_AGE_DAYS}-day eligibility window)" ;;
    *) fail "node: unexpected resolution failure" ;;
  esac
}

process_github_release_dep() {
  local dep="$1"
  local current_version
  local current_amd64_sha
  local current_arm64_sha
  local version_arg_name
  local sha_var_name
  local candidate
  local candidate_version
  local candidate_amd64_sha
  local candidate_arm64_sha
  local status

  version_arg_name="$(version_arg_for_dep "${dep}")"
  sha_var_name="$(sha_var_for_dep "${dep}")"
  current_version="$(extract_arg_value "${DOCKERFILE_PATH}" "${version_arg_name}")"
  current_amd64_sha="$(extract_arch_value "${DOCKERFILE_PATH}" amd64 "${sha_var_name}")"
  current_arm64_sha="$(extract_arch_value "${DOCKERFILE_PATH}" arm64 "${sha_var_name}")"

  assert_non_empty "${dep}: could not parse ${version_arg_name}" "${current_version}"
  assert_non_empty "${dep}: could not parse amd64 ${sha_var_name}" "${current_amd64_sha}"
  assert_non_empty "${dep}: could not parse arm64 ${sha_var_name}" "${current_arm64_sha}"
  validate_plain_sha256 "${current_amd64_sha}" || fail "${dep}: current amd64 digest is invalid"
  validate_plain_sha256 "${current_arm64_sha}" || fail "${dep}: current arm64 digest is invalid"

  status=0
  candidate="$(resolve_github_release_candidate "${dep}")" || status=$?
  if [ "${status}" -eq 0 ]; then
    IFS=$'\t' read -r candidate_version candidate_amd64_sha candidate_arm64_sha <<< "${candidate}"

    validate_plain_sha256 "${candidate_amd64_sha}" || fail "${dep}: resolved amd64 digest is invalid"
    validate_plain_sha256 "${candidate_arm64_sha}" || fail "${dep}: resolved arm64 digest is invalid"

    if [ "${candidate_version}" = "${current_version}" ] \
      && [ "${candidate_amd64_sha}" = "${current_amd64_sha}" ] \
      && [ "${candidate_arm64_sha}" = "${current_arm64_sha}" ]; then
      append_summary "${dep}: unchanged (${current_version})"
      return
    fi

    replace_arg_value "${STAGED_DOCKERFILE}" "${version_arg_name}" "${candidate_version}"
    replace_arch_value "${STAGED_DOCKERFILE}" amd64 "${sha_var_name}" "${candidate_amd64_sha}"
    replace_arch_value "${STAGED_DOCKERFILE}" arm64 "${sha_var_name}" "${candidate_arm64_sha}"
    CHANGED=1

    if [ "${candidate_version}" = "${current_version}" ]; then
      append_summary "${dep}: refreshed digests for ${current_version}"
    else
      append_summary "${dep}: ${current_version} -> ${candidate_version}"
    fi
    return
  fi

  case "${status}" in
    2) append_summary "${dep}: skipped (no stable release has cleared the ${MINIMUM_RELEASE_AGE_DAYS}-day eligibility window yet)" ;;
    *) fail "${dep}: unexpected resolution failure" ;;
  esac
}

verify_staged_dockerfile() {
  local actual
  local dep
  local version_arg_name
  local sha_var_name

  actual="$(extract_syntax_digest "${STAGED_DOCKERFILE}")"
  validate_prefixed_sha256 "${actual}" || fail "staged Dockerfile syntax digest is invalid"

  actual="$(extract_from_digest "${STAGED_DOCKERFILE}")"
  validate_prefixed_sha256 "${actual}" || fail "staged node base image digest is invalid"

  for dep in "${GITHUB_RELEASE_DEPS[@]}"; do
    version_arg_name="$(version_arg_for_dep "${dep}")"
    sha_var_name="$(sha_var_for_dep "${dep}")"

    actual="$(extract_arg_value "${STAGED_DOCKERFILE}" "${version_arg_name}")"
    assert_non_empty "${dep}: staged ${version_arg_name} is missing" "${actual}"

    actual="$(extract_arch_value "${STAGED_DOCKERFILE}" amd64 "${sha_var_name}")"
    validate_plain_sha256 "${actual}" || fail "${dep}: staged amd64 ${sha_var_name} is invalid"

    actual="$(extract_arch_value "${STAGED_DOCKERFILE}" arm64 "${sha_var_name}")"
    validate_plain_sha256 "${actual}" || fail "${dep}: staged arm64 ${sha_var_name} is invalid"
  done
}

print_summary() {
  local line
  for line in "${SUMMARY_LINES[@]}"; do
    printf '%s\n' "${line}"
  done
}

main() {
  require_command awk
  require_command curl
  require_command git
  require_command jq
  require_command mktemp
  require_command sed

  ensure_positive_integer
  [ -f "${DOCKERFILE_PATH}" ] || fail "Dockerfile not found: ${DOCKERFILE_PATH}"
  ensure_clean_git_worktree
  resolve_github_api_token

  THRESHOLD_EPOCH="$(( $(current_epoch) - MINIMUM_RELEASE_AGE_DAYS * 86400 ))"
  STAGED_DOCKERFILE="$(mktemp)"
  cp "${DOCKERFILE_PATH}" "${STAGED_DOCKERFILE}"

  process_docker_syntax
  process_node_base_image

  local dep
  for dep in "${GITHUB_RELEASE_DEPS[@]}"; do
    process_github_release_dep "${dep}"
  done

  verify_staged_dockerfile

  if [ "${CHANGED}" -eq 1 ]; then
    mv "${STAGED_DOCKERFILE}" "${DOCKERFILE_PATH}"
    STAGED_DOCKERFILE=""
    print_summary
    printf 'Dockerfile updated.\n'
  else
    print_summary
    printf 'No changes.\n'
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
