#!/usr/bin/env bash
set -euo pipefail

# Reduce ANSI from tools when they respect these (logs still stripped before PR comment).
export NO_COLOR=1
export FORCE_COLOR=0
export CI="${CI:-true}"

MAX_COMMENT_LINES=500
MAX_COMMENT_CHARS=62000
MAX_TOTAL_COMMENT_CHARS=64000

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

# Per-check status for PR summary: pass | fail | skip
SEC_GA_STATUS=skip
SEC_GA_BODY=""
SEC_CL_STATUS=skip
SEC_CL_BODY=""
SEC_RENOVATE_STATUS=skip
SEC_RENOVATE_BODY=""
SEC_VULN_STATUS=skip
SEC_VULN_BODY=""
# vuln body is markdown (true) or plain log (false)
SEC_VULN_IS_MD="false"

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

# Strip ANSI escape sequences (CSI + OSC hyperlink) so GitHub PR comments stay readable.
strip_ansi() {
  if [ -z "${1:-}" ]; then
    printf ''
    return
  fi
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed 's/\x1b\][0-9;]*[^\x07]*//g' | tr -d '\r'
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

table_result_cell() {
  case "$1" in
    pass) printf '%s' '✅ **Passed**' ;;
    fail) printf '%s' '❌ **Failed**' ;;
    skip) printf '%s' '⊘ **Skipped**' ;;
    *) printf '%s' '—' ;;
  esac
}

status_badge() {
  case "$1" in
    pass) printf '%s' '✅ Passed' ;;
    fail) printf '%s' '❌ Failed' ;;
    skip) printf '%s' '⊘ Skipped' ;;
    *) printf '%s' '—' ;;
  esac
}

escape_summary_title() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

append_detail_block() {
  local title="$1"
  local status="$2"
  local body="$3"
  local is_md="${4:-false}"
  local esc_title
  esc_title=$(escape_summary_title "$title")

  printf '<details>\n<summary><strong>%s</strong> — %s</summary>\n\n' "$esc_title" "$(status_badge "$status")"

  case "$status" in
    skip)
      printf '%s\n\n' "$body"
      ;;
    *)
      if is_true "$is_md"; then
        printf '%s\n\n' "$(truncate_comment_body "$body")"
      else
        printf '```text\n%s\n```\n\n' "$(truncate_comment_body "$(strip_ansi "$body")")"
      fi
      ;;
  esac
  printf '</details>\n\n'
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

render_combined_pr_comment() {
  local overall_emoji overall_word
  if [ "$failed" -eq 0 ]; then
    overall_emoji="✅"
    overall_word="**PASSED**"
  else
    overall_emoji="❌"
    overall_word="**FAILED**"
  fi

  local short_sha run_url
  short_sha=$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH" | cut -c1-7)
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-unknown}"

  printf '%s\n\n' "## common-lint results"
  printf '%s **Overall:** %s\n\n' "$overall_emoji" "$overall_word"
  printf '%s **Run:** [%s](%s) · **Commit:** `%s`\n\n' "🔗" "${GITHUB_RUN_ID:-unknown}" "$run_url" "$short_sha"
  printf '%s\n' "| Check | Result |"
  printf '%s\n' "| --- | --- |"
  printf '| GitHub Actions lint (actionlint, ghalint, zizmor) | %s |\n' "$(table_result_cell "$SEC_GA_STATUS")"
  printf '| commitlint | %s |\n' "$(table_result_cell "$SEC_CL_STATUS")"
  printf '| renovate-check | %s |\n' "$(table_result_cell "$SEC_RENOVATE_STATUS")"
  printf '| vuln-scan (Trivy) | %s |\n' "$(table_result_cell "$SEC_VULN_STATUS")"
  printf '\n---\n\n'

  append_detail_block "1. GitHub Actions lint" "$SEC_GA_STATUS" "$SEC_GA_BODY" false
  append_detail_block "2. commitlint" "$SEC_CL_STATUS" "$SEC_CL_BODY" false
  append_detail_block "3. renovate-check" "$SEC_RENOVATE_STATUS" "$SEC_RENOVATE_BODY" false
  if is_true "$SEC_VULN_IS_MD"; then
    append_detail_block "4. vuln-scan (Trivy)" "$SEC_VULN_STATUS" "$SEC_VULN_BODY" "true"
  else
    append_detail_block "4. vuln-scan (Trivy)" "$SEC_VULN_STATUS" "$SEC_VULN_BODY" "false"
  fi
}

post_pr_comment_once() {
  local full="$1"

  if [ "${#full}" -gt "$MAX_TOTAL_COMMENT_CHARS" ]; then
    full="${full:0:$MAX_TOTAL_COMMENT_CHARS}"
    full="${full}"$'\n\n... (truncated: comment size limit)\n'
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
    if [ "${http_code:-}" = "403" ]; then
      echo "::warning::Could not post PR comment (HTTP 403). Add \`pull-requests: write\` under \`permissions:\` in the workflow that runs this action. Fork PRs use a read-only token for security; comments from GITHUB_TOKEN are not possible unless you use a different trigger or credential (see GitHub Actions docs on GITHUB_TOKEN permissions)."
    else
      echo "::warning::Could not post PR comment (HTTP ${http_code:-unknown}, curl exit ${curl_exit}). ${err}"
    fi
  fi
  rm -f "$resp_file"
}

changed_files=$(get_changed_files)

if is_true "$INPUT_GITHUB_ACTIONS_LINT"; then
  if echo "$changed_files" | should_run_github_actions_lint; then
    cap=$(mktemp)
    ga_failed=0
    echo "::group::github-actions-lint (actionlint, ghalint, zizmor)"
    {
      actionlint || ga_failed=1
      ghalint run || ga_failed=1
      zizmor . || ga_failed=1
    } >"$cap" 2>&1
    cat "$cap"
    echo "::endgroup::"
    SEC_GA_BODY=$(cat "$cap")
    rm -f "$cap"
    if [ "$ga_failed" -eq 0 ]; then
      SEC_GA_STATUS=pass
    else
      SEC_GA_STATUS=fail
      failed=1
    fi
  else
    echo "Skipping github-actions-lint: no matching files in this change set."
    SEC_GA_STATUS=skip
    SEC_GA_BODY="No matching files in this change set (e.g. \`.github/workflows/*.yml\` or composite \`action.yml\`)."
  fi
else
  echo "Skipping github-actions-lint (disabled)."
  SEC_GA_STATUS=skip
  SEC_GA_BODY="Input \`github-actions-lint\` is disabled."
fi

if is_true "$INPUT_COMMITLINT"; then
  cap=$(mktemp)
  cl_failed=0
  echo "::group::commitlint"
  COMMITLINT_CONFIG=$(commitlint_config_path)
  {
    if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
      if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
        from=$(jq -r '.pull_request.base.sha' "$GITHUB_EVENT_PATH")
        to=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")
        git fetch -q origin "$from" 2>/dev/null || true
        git fetch -q origin "$to" 2>/dev/null || true
        commitlint --config "$COMMITLINT_CONFIG" --from "$from" --to "$to" || cl_failed=1
      elif [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
        after=$(jq -r '.after // empty' "$GITHUB_EVENT_PATH")
        if [ -n "$after" ] && from=$(resolve_push_from); then
          commitlint --config "$COMMITLINT_CONFIG" --from "$from" --to "$after" || cl_failed=1
        else
          commitlint_default_range || cl_failed=1
        fi
      else
        commitlint_default_range || cl_failed=1
      fi
    else
      commitlint_default_range || cl_failed=1
    fi
  } >"$cap" 2>&1
  cat "$cap"
  echo "::endgroup::"
  SEC_CL_BODY=$(cat "$cap")
  rm -f "$cap"
  if [ "$cl_failed" -eq 0 ]; then
    SEC_CL_STATUS=pass
  else
    SEC_CL_STATUS=fail
    failed=1
  fi
else
  echo "Skipping commitlint (disabled)."
  SEC_CL_STATUS=skip
  SEC_CL_BODY="Input \`commitlint\` is disabled."
fi

if is_true "$INPUT_RENOVATE_CHECK"; then
  if echo "$changed_files" | should_run_renovate_check; then
    cap=$(mktemp)
    reno_failed=0
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
        reno_failed=1
      else
        renovate-config-validator "${args[@]}" || reno_failed=1
      fi
    } >"$cap" 2>&1
    cat "$cap"
    echo "::endgroup::"
    SEC_RENOVATE_BODY=$(cat "$cap")
    rm -f "$cap"
    if [ "$reno_failed" -eq 0 ]; then
      SEC_RENOVATE_STATUS=pass
    else
      SEC_RENOVATE_STATUS=fail
      failed=1
    fi
  else
    echo "Skipping renovate-check: no matching files in this change set."
    SEC_RENOVATE_STATUS=skip
    SEC_RENOVATE_BODY="No matching files in this change set (\`renovate.json\`, \`renovate.json5\`, or \`.github/renovate.json\`)."
  fi
else
  echo "Skipping renovate-check (disabled)."
  SEC_RENOVATE_STATUS=skip
  SEC_RENOVATE_BODY="Input \`renovate-check\` is disabled."
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
    SEC_VULN_STATUS=fail
    SEC_VULN_IS_MD="false"
    SEC_VULN_BODY=$(printf '%s\n\n%s' "trivy exited with code ${trivy_exit}" "$(cat "$trivy_log")")
  else
    total=$(jq '[.Results[]? | .Vulnerabilities[]?] | length' "$trivy_json")
    if [ "${total:-0}" -eq 0 ]; then
      echo "No vulnerabilities detected (filesystem scan)."
    else
      jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]? | "\($t)\t\(.PkgName)\t\(.InstalledVersion // "")\t\(.VulnerabilityID)\t\(.Severity)"' "$trivy_json"
    fi
    if jq -e '[.Results[]? | .Vulnerabilities[]? | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length > 0' "$trivy_json" >/dev/null 2>&1; then
      failed=1
      SEC_VULN_STATUS=fail
    else
      SEC_VULN_STATUS=pass
    fi
    SEC_VULN_IS_MD="true"
    SEC_VULN_BODY="$(build_trivy_pr_comment_body "$trivy_json")"
  fi
  echo "::endgroup::"
  rm -f "$trivy_json" "$trivy_log"
else
  echo "Skipping vuln-scan (disabled)."
  SEC_VULN_STATUS=skip
  SEC_VULN_IS_MD="false"
  SEC_VULN_BODY="Input \`vuln-scan\` is disabled."
fi

if should_post_pr_comment; then
  combined=$(mktemp)
  render_combined_pr_comment >"$combined"
  post_pr_comment_once "$(cat "$combined")"
  rm -f "$combined"
fi

exit "$failed"
