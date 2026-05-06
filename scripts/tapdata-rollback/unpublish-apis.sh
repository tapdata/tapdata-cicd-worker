#!/usr/bin/env bash
# Unpublish TapData APIs for rollback
# 1. Query API ids and tableNames via GET /api/Modules
# 2. Unpublish each API via PATCH /api/Modules
# Required env vars: TAPDATA_TOKEN, TAPDATA_URL
# Optional env vars: API_NAMES (comma separated, if empty unpublishes all APIs)
# Output: unpublished_api_ids (comma separated, via GITHUB_OUTPUT)
#         unpublished_apis_file (path to JSON file with id, status, tableName, via GITHUB_OUTPUT)
set -euo pipefail

echo "=== Unpublishing APIs ==="

if [[ -z "${TAPDATA_URL:-}" ]]; then
  echo "::error::TAPDATA_URL is not set or empty"
  exit 1
fi

BASE_URL="${TAPDATA_URL}"

API_BASE="${BASE_URL%/}/api"

# ── Step 1: Build filter and query API ids and tableNames ──
if [[ -n "${API_NAMES:-}" ]]; then
  echo "Mode: unpublish specified APIs"

  IFS=',' read -ra RAW_APIS <<< "${API_NAMES}"
  TRIMMED_APIS=()
  for api in "${RAW_APIS[@]}"; do
    trimmed=$(echo "${api}" | xargs)
    if [[ -n "${trimmed}" ]]; then
      TRIMMED_APIS+=("${trimmed}")
    fi
  done

  if [[ ${#TRIMMED_APIS[@]} -eq 0 ]]; then
    echo "::error::No valid API names provided"
    exit 1
  fi

  INQ_ARRAY=$(printf '%s\n' "${TRIMMED_APIS[@]}" | jq -R . | jq -s .)
  FILTER=$(jq -n -c --argjson inq "${INQ_ARRAY}" '{
    "fields": {"id": true, "tableName": true, "status": true},
    "where": {"name": {"$inq": $inq}}
  }')

  echo "Querying API IDs for: ${TRIMMED_APIS[*]}"
else
  echo "Mode: unpublish all APIs"
  FILTER=$(jq -n -c '{"fields": {"id": true, "tableName": true, "status": true}}')
  echo "Querying all APIs..."
fi

ENCODED_FILTER=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "${FILTER}")
QUERY_URL="${API_BASE}/Modules?access_token=${TAPDATA_TOKEN}&filter=${ENCODED_FILTER}"

RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${QUERY_URL}")
HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 ]]; then
  echo "::error::Failed to query APIs: HTTP ${HTTP_CODE} - ${BODY}"
  exit 1
fi

API_COUNT=$(echo "${BODY}" | jq '.data.items | length')

if [[ "${API_COUNT}" -eq 0 ]]; then
  echo "No APIs found, skipping unpublish"
  echo "unpublished_api_ids=" >> "${GITHUB_OUTPUT}"
  echo "=== Unpublish APIs Complete ==="
  exit 0
fi

echo "Found ${API_COUNT} API(s):"
echo "${BODY}" | jq -r '.data.items[] | "  - \(.tableName) (id: \(.id), status: \(.status))"'

# ── Step 2: Unpublish only active APIs ──
ACTIVE_COUNT=$(echo "${BODY}" | jq '[.data.items[] | select(.status == "active")] | length')

if [[ "${ACTIVE_COUNT}" -eq 0 ]]; then
  echo "No active APIs found, skipping unpublish"
else
  echo "Unpublishing ${ACTIVE_COUNT} active API(s)..."
  PATCH_URL="${API_BASE}/Modules?access_token=${TAPDATA_TOKEN}"

  while IFS= read -r item; do
    API_ID=$(echo "${item}" | jq -r '.id')
    TABLE_NAME=$(echo "${item}" | jq -r '.tableName')

    echo "Unpublishing API: ${TABLE_NAME} (id: ${API_ID})..."

    PAYLOAD=$(jq -n -c \
      --arg id "${API_ID}" \
      --arg tableName "${TABLE_NAME}" \
      '{id: $id, tableName: $tableName, status: "pending"}')

    PATCH_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${PATCH_URL}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}")

    PATCH_HTTP_CODE=$(echo "${PATCH_RESPONSE}" | tail -n1)
    PATCH_BODY=$(echo "${PATCH_RESPONSE}" | sed '$d')

    if [[ "${PATCH_HTTP_CODE}" -ne 200 ]]; then
      echo "::error::Failed to unpublish API '${TABLE_NAME}': HTTP ${PATCH_HTTP_CODE} - ${PATCH_BODY}"
      exit 1
    fi

    RESP_CODE=$(echo "${PATCH_BODY}" | jq -r '.code // empty')
    if [[ "${RESP_CODE}" != "ok" ]]; then
      echo "::error::Failed to unpublish API '${TABLE_NAME}': response code '${RESP_CODE}' - ${PATCH_BODY}"
      exit 1
    fi

    echo "  API '${TABLE_NAME}' unpublished successfully"
  done < <(echo "${BODY}" | jq -c '.data.items[] | select(.status == "active")')

  echo "All ${ACTIVE_COUNT} active API(s) unpublished successfully"
fi

# Output all API IDs
UNPUBLISHED_IDS=$(echo "${BODY}" | jq -r '[.data.items[].id] | join(",")')
echo "unpublished_api_ids=${UNPUBLISHED_IDS}" >> "${GITHUB_OUTPUT}"

# Save id, status, tableName to a temporary JSON file
UNPUBLISHED_APIS_FILE="/tmp/unpublished-apis-${GITHUB_RUN_ID:-$$}.json"
echo "${BODY}" | jq '[.data.items[] | {id, status, tableName}]' > "${UNPUBLISHED_APIS_FILE}"
echo "Unpublished APIs file: ${UNPUBLISHED_APIS_FILE}"
echo "unpublished_apis_file=${UNPUBLISHED_APIS_FILE}" >> "${GITHUB_OUTPUT}"

echo "=== Unpublish APIs Complete ==="
