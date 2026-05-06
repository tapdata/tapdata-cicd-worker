#!/usr/bin/env bash
# Collect deployment results and generate deployment report
# Required env vars: DEPLOY_DIR, DEPLOYMENT_REF, TARGET_ENV, PROJECT,
#   GITHUB_ACTOR,
#   CHANGED_CONNECTIONS, CHANGED_TASKS, CHANGED_APIS, CHANGED_GROUP_INFO,
#   PREPARATION_RESULT, CONNECTIONS_RESULT, TASKS_RESULT, APIS_RESULT, GROUP_INFO_RESULT
set -euo pipefail

echo "=== Generating Deployment Report ==="

mkdir -p "${DEPLOY_DIR}"

# --- Map job result to emoji ---
result_icon() {
  case "${1}" in
    success)  echo "✅" ;;
    failure)  echo "❌" ;;
    cancelled) echo "⚠️" ;;
    skipped)  echo "⏭️" ;;
    *)        echo "❓" ;;
  esac
}

# --- Determine overall result ---
if [[ "${PREPARATION_RESULT}" == "success" && "${CONNECTIONS_RESULT}" == "success" && "${TASKS_RESULT}" == "success" && "${APIS_RESULT}" == "success" && "${GROUP_INFO_RESULT}" == "success" ]]; then
  OVERALL_RESULT="✅ SUCCESS"
elif [[ "${CONNECTIONS_RESULT}" == "failure" || "${TASKS_RESULT}" == "failure" || "${APIS_RESULT}" == "failure" || "${GROUP_INFO_RESULT}" == "failure" ]]; then
  OVERALL_RESULT="❌ FAILURE"
else
  OVERALL_RESULT="⚠️ PARTIAL"
fi

# --- Count changes from import responses ---
count_changes() {
  local json="${1:-}"
  if [[ -z "${json}" || "${json}" == "null" ]]; then
    echo "0"
    return
  fi
  local count
  count=$(echo "${json}" | jq 'if type == "array" then length elif .data? then (.data | if type == "array" then length else 1 end) else 1 end' 2>/dev/null || echo "0")
  echo "${count}"
}

# --- Format diff details as markdown list ---
format_diff_details() {
  local json="${1:-}"
  local resource_label="${2:-}"
  if [[ -z "${json}" || "${json}" == "null" ]]; then
    echo "_No changes_"
    return
  fi
  # Try to extract name/id from each diff item
  local details
  details=$(echo "${json}" | jq -r '
    if type == "array" then
      .[] | "- \(.name // .id // "(unknown)")"
    elif type == "object" then
      "- \(.name // .id // "(unknown)")"
    else
      "- (raw: \(.))"
    end
  ' 2>/dev/null || echo "- _(unable to parse diff)_")
  if [[ -z "${details}" ]]; then
    echo "_No changes_"
  else
    echo "${details}"
  fi
}

CONNECTIONS_COUNT=$(count_changes "${CHANGED_CONNECTIONS:-}")
TASKS_COUNT=$(count_changes "${CHANGED_TASKS:-}")
APIS_COUNT=$(count_changes "${CHANGED_APIS:-}")
GROUP_INFO_COUNT=$(count_changes "${CHANGED_GROUP_INFO:-}")

CONNECTIONS_DETAILS=$(format_diff_details "${CHANGED_CONNECTIONS:-}" "Connections")
TASKS_DETAILS=$(format_diff_details "${CHANGED_TASKS:-}" "Tasks")
APIS_DETAILS=$(format_diff_details "${CHANGED_APIS:-}" "APIs")
GROUP_INFO_DETAILS=$(format_diff_details "${CHANGED_GROUP_INFO:-}" "Group Info")

# --- Timestamp ---
REPORT_TIME=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# --- Generate report ---
REPORT_FILE="${DEPLOY_DIR}/deployment-summary.md"

cat > "${REPORT_FILE}" <<EOF
## TapData Deployment Report

| Item | Value |
| --- | --- |
| Report Time | ${REPORT_TIME} |
| Operator | ${GITHUB_ACTOR} |
| Target Environment | ${TARGET_ENV} |
| Project | ${PROJECT} |
| Deployment Ref | ${DEPLOYMENT_REF} |
| Overall Result | ${OVERALL_RESULT} |

### Job Results

| Job | Result | Status |
| --- | --- | --- |
| Preparation | $(result_icon "${PREPARATION_RESULT}") ${PREPARATION_RESULT} | - |
| Deploy Connections | $(result_icon "${CONNECTIONS_RESULT}") ${CONNECTIONS_RESULT} | ${CONNECTIONS_COUNT} changed |
| Deploy Tasks | $(result_icon "${TASKS_RESULT}") ${TASKS_RESULT} | ${TASKS_COUNT} changed |
| Deploy APIs | $(result_icon "${APIS_RESULT}") ${APIS_RESULT} | ${APIS_COUNT} changed |
| Deploy Group Info | $(result_icon "${GROUP_INFO_RESULT}") ${GROUP_INFO_RESULT} | ${GROUP_INFO_COUNT} changed |

### Deploy Details

#### Connections (${CONNECTIONS_COUNT} changed)
${CONNECTIONS_DETAILS}

#### Tasks (${TASKS_COUNT} changed)
${TASKS_DETAILS}

#### APIs (${APIS_COUNT} changed)
${APIS_DETAILS}

#### Group Info (${GROUP_INFO_COUNT} changed)
${GROUP_INFO_DETAILS}
EOF

echo "Report saved to ${REPORT_FILE}"
cat "${REPORT_FILE}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "${REPORT_FILE}" >> "${GITHUB_STEP_SUMMARY}"
  echo "Report appended to step summary"
fi

echo "=== Report Generated ==="
