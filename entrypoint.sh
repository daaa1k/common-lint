#!/usr/bin/env bash
set -euo pipefail

MAX_COMMENT_LINES=500
MAX_COMMENT_CHARS=62000

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
INPUT_VULN_SCAN="${INPUT_VULN_SCAN:-true}"
INPUT_POST_PR_COMMENTS="${INPUT_POST_PR_COMMENTS:-true}"

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

commitlint_config_path() {
  node /opt/npm-deps/merge-commitlint-config.mjs
}

commitlint_default_range() {
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    commitlint --config "$COMMITLINT_CONFIG" --from HEAD~1 --to HEAD
  else
    commitlint --config "$COMMITLINT_CONFIG" --from HEAD --to HEAD
  fi
}

should_post_pr_comment() {
  is_true "${INPUT_POST_PR_COMMENTS:-true}" || return 1
  [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || return 1
  [ -n "${GITHUB_TOKEN:-}" ] || return 1
  [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ] || return 1
  return 0
}

build_comment_header() {
  local scan_title="$1"
  local short_sha
  short_sha=$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH" | cut -c1-7)
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  printf '### common-lint: %s\n\n**Run:** [%s](%s) · **Commit:** `%s`\n\n' \
    "$scan_title" "${GITHUB_RUN_ID:-unknown}" "$run_url" "$short_sha"
}

truncate_comment_body() {
  local text="$1"
  if [ -z "$text" ]; then
    printf '%s' "(no output)"
    return
  fi
  local line_trunc=false
  local char_trunc=false
  local line_count
  line_count=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
  local out
  out=$(printf '%s\n' "$text" | head -n "$MAX_COMMENT_LINES")
  if [ "${line_count:-0}" -gt "$MAX_COMMENT_LINES" ]; then
    line_trunc=true
  fi
  if [ "${#out}" -gt "$MAX_COMMENT_CHARS" ]; then
    out="${out:0:$MAX_COMMENT_CHARS}"
    char_trunc=true
  fi
  printf '%s' "$out"
  if [ "$line_trunc" = true ] || [ "$char_trunc" = true ]; then
    printf '\n\n... (truncated'
    [ "$line_trunc" = true ] && printf ': more than %s lines' "$MAX_COMMENT_LINES"
    [ "$line_trunc" = true ] && [ "$char_trunc" = true ] && printf '; '
    [ "$char_trunc" = true ] && printf 'more than %s characters' "$MAX_COMMENT_CHARS"
    printf ')\n'
  fi
}

post_pr_comment_scan() {
  local scan_name="$1"
  local mode="$2"
  local body="$3"

  if ! should_post_pr_comment; then
    return 0
  fi

  local header
  header=$(build_comment_header "$scan_name")

  local full
  if [ "$mode" = "skip" ]; then
    full="${header}${body}"
  elif [ "$mode" = "output-md" ]; then
    local truncated_md
    truncated_md=$(truncate_comment_body "$body")
    full="${header}${truncated_md}"
  else
    local truncated
    truncated=$(truncate_comment_body "$body")
    full="${header}~~~
${truncated}
~~~"
  fi

  if [ "${#full}" -gt 65500 ]; then
    full="${full:0:65500}"
    full="${full}"$'\n\n... (truncated: GitHub comment size limit)\n'
  fi

  local api_url="${GITHUB_API_URL:-https://api.github.com}"
  local pr_number
  pr_number=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
  local resp_file
  resp_file=$(mktemp)
  local http_code
  set +e
  http_code=$(
    curl -sS -w '%{http_code}' -o "$resp_file" -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$api_url/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments" \
      -d "$(jq -n --arg body "$full" '{body: $body}')"
  )
  curl_exit=$?
  set -e

  if [ "$curl_exit" -ne 0 ] || [ "$http_code" != "201" ]; then
    local err
    err=$(head -c 400 "$resp_file" 2>/dev/null || true)
    echo "::warning::Could not post PR comment for ${scan_name} (HTTP ${http_code:-unknown}, curl exit ${curl_exit}). ${err}"
  fi
  rm -f "$resp_file"
}

build_trivy_pr_comment_body() {
  local json_file="$1"
  jq -r '
    def vulns: [.Results[]? | .Vulnerabilities[]?];

    (vulns | length) as $total
    | if $total == 0 then
        "**Summary:** No vulnerabilities detected.\n"
      else
        "**Summary:** \($total) finding(s)\n\n"
        + "**Severity counts:** "
        + ([vulns | group_by(.Severity) | .[] | "\(.[0].Severity): \(length)"] | join(" | "))
        + "\n\n"
        + (
            (
              [.Results[]? | .Target as $t | .Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH") | . + { ScanTarget: $t }]
              | sort_by(if .Severity == "CRITICAL" then 0 elif .Severity == "HIGH" then 1 else 2 end)
              | .[0:20]
            )
            | if length == 0 then
                "**CRITICAL/HIGH:** none\n"
              else
                "**CRITICAL/HIGH (first 20):**\n\n"
                + (map("- **\(.VulnerabilityID)** (\(.Severity)) — \(.PkgName) @ \(.InstalledVersion // "") — \(.ScanTarget)") | join("\n"))
              end
          )
      end
  ' "$json_file"
}

changed_files=$(get_changed_files)

if is_true "$INPUT_GITHUB_ACTIONS_LINT"; then
  if echo "$changed_files" | should_run_github_actions_lint; then
    cap=$(mktemp)
    echo "::group::github-actions-lint (actionlint, ghalint, zizmor)"
    {
      actionlint || failed=1
      ghalint run || failed=1
      zizmor . || failed=1
    } >"$cap" 2>&1
    cat "$cap"
    echo "::endgroup::"
    post_pr_comment_scan "github-actions-lint" output "$(cat "$cap")"
    rm -f "$cap"
  else
    echo "Skipping github-actions-lint: no matching files in this change set."
    post_pr_comment_scan "github-actions-lint" skip "Skipping: no matching files in this change set (e.g. \`.github/workflows/*.yml\` or composite \`action.yml\`)."
  fi
else
  echo "Skipping github-actions-lint (disabled)."
  post_pr_comment_scan "github-actions-lint" skip "Skipping: \`github-actions-lint\` is disabled."
fi

if is_true "$INPUT_COMMITLINT"; then
  cap=$(mktemp)
  echo "::group::commitlint"
  COMMITLINT_CONFIG=$(commitlint_config_path)
  {
    if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
      if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
        from=$(jq -r '.pull_request.base.sha' "$GITHUB_EVENT_PATH")
        to=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")
        git fetch -q origin "$from" 2>/dev/null || true
        git fetch -q origin "$to" 2>/dev/null || true
        commitlint --config "$COMMITLINT_CONFIG" --from "$from" --to "$to" || failed=1
      elif [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
        after=$(jq -r '.after // empty' "$GITHUB_EVENT_PATH")
        if [ -n "$after" ] && from=$(resolve_push_from); then
          commitlint --config "$COMMITLINT_CONFIG" --from "$from" --to "$after" || failed=1
        else
          commitlint_default_range || failed=1
        fi
      else
        commitlint_default_range || failed=1
      fi
    else
      commitlint_default_range || failed=1
    fi
  } >"$cap" 2>&1
  cat "$cap"
  echo "::endgroup::"
  post_pr_comment_scan "commitlint" output "$(cat "$cap")"
  rm -f "$cap"
else
  echo "Skipping commitlint (disabled)."
  post_pr_comment_scan "commitlint" skip "Skipping: \`commitlint\` is disabled."
fi

if is_true "$INPUT_RENOVATE_CHECK"; then
  if echo "$changed_files" | should_run_renovate_check; then
    cap=$(mktemp)
    echo "::group::renovate-config-validator"
    {
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
    } >"$cap" 2>&1
    cat "$cap"
    echo "::endgroup::"
    post_pr_comment_scan "renovate-check" output "$(cat "$cap")"
    rm -f "$cap"
  else
    echo "Skipping renovate-check: no matching files in this change set."
    post_pr_comment_scan "renovate-check" skip "Skipping: no matching files in this change set (\`renovate.json\`, \`renovate.json5\`, or \`.github/renovate.json\`)."
  fi
else
  echo "Skipping renovate-check (disabled)."
  post_pr_comment_scan "renovate-check" skip "Skipping: \`renovate-check\` is disabled."
fi

if is_true "$INPUT_VULN_SCAN"; then
  trivy_json=$(mktemp)
  trivy_log=$(mktemp)
  echo "::group::trivy (vulnerability scan)"
  set +e
  trivy fs --scanners vuln --format json --output "$trivy_json" \
    --skip-dirs node_modules,.git \
    --no-progress \
    . >"$trivy_log" 2>&1
  trivy_exit=$?
  set -e
  cat "$trivy_log"

  if [ "$trivy_exit" -ne 0 ]; then
    failed=1
    post_pr_comment_scan "vuln-scan" output "$(printf '%s\n\n%s' "trivy exited with code ${trivy_exit}" "$(cat "$trivy_log")")"
  else
    total=$(jq '[.Results[]? | .Vulnerabilities[]?] | length' "$trivy_json")
    if [ "${total:-0}" -eq 0 ]; then
      echo "No vulnerabilities detected (filesystem scan)."
    else
      jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]? | "\($t)\t\(.PkgName)\t\(.InstalledVersion // "")\t\(.VulnerabilityID)\t\(.Severity)"' "$trivy_json"
    fi
    if jq -e '[.Results[]? | .Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length > 0' "$trivy_json" >/dev/null 2>&1; then
      failed=1
    fi
    post_pr_comment_scan "vuln-scan" output-md "$(build_trivy_pr_comment_body "$trivy_json")"
  fi
  echo "::endgroup::"
  rm -f "$trivy_json" "$trivy_log"
else
  echo "Skipping vuln-scan (disabled)."
  post_pr_comment_scan "vuln-scan" skip "Skipping: \`vuln-scan\` is disabled."
fi

exit "$failed"
