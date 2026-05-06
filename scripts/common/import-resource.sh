#!/usr/bin/env bash
# Import resource (connections/tasks/apis) via TapData API
# Usage: import-resource.sh <resource_type>
# resource_type: connections | tasks | migrate/tasks | sync/tasks | apis
# Required env vars: DEPLOY_DIR, TAPDATA_TOKEN, TAPDATA_URL
# Optional env vars: ARCHIVE_NAME
set -euo pipefail

RESOURCE_TYPE="${1:-}"

echo "=== Importing ${RESOURCE_TYPE} via TapData API ==="

# Validate inputs
if [[ -z "${RESOURCE_TYPE}" ]]; then
  echo "::error::Usage: import-resource.sh <connections|tasks|migrate/tasks|sync/tasks|apis>"
  exit 1
fi

if [[ -z "${DEPLOY_DIR:-}" ]]; then
  echo "::error::DEPLOY_DIR is not set or empty"
  exit 1
fi

if [[ -z "${TAPDATA_TOKEN:-}" ]]; then
  echo "::error::TAPDATA_TOKEN is not set or empty"
  exit 1
fi

if [[ -z "${TAPDATA_URL:-}" ]]; then
  echo "::error::TAPDATA_URL is not set or empty"
  exit 1
fi

BASE_URL="${TAPDATA_URL}"

# Determine API path based on resource type
case "${RESOURCE_TYPE}" in
  connections)
    API_PATH="api/groupInfo/import/connections"
    ;;
  tasks)
    API_PATH="api/groupInfo/import/tasks"
    ;;
  migrate/tasks)
    API_PATH="api/groupInfo/import/migrate/tasks"
    ;;
  sync/tasks)
    API_PATH="api/groupInfo/import/sync/tasks"
    ;;
  apis)
    API_PATH="api/groupInfo/import/apis"
    ;;
  users)
    API_PATH="api/groupInfo/import/users"
    ;;
  groupInfo)
    API_PATH="api/groupInfo/import/groupInfo"
    ;;
  *)
    echo "::error::Unknown resource type: ${RESOURCE_TYPE}. Expected: connections|tasks|migrate/tasks|sync/tasks|apis|users|groupInfo"
    exit 1
    ;;
esac

API_URL="${BASE_URL%/}/${API_PATH}"
ACCESS_TOKEN_ENCODED=$(jq -nr --arg v "${TAPDATA_TOKEN}" '$v|@uri')

if [[ "${API_URL}" == *\?* ]]; then
  IMPORT_URL="${API_URL}&access_token=${ACCESS_TOKEN_ENCODED}"
else
  IMPORT_URL="${API_URL}?access_token=${ACCESS_TOKEN_ENCODED}"
fi

# Locate tar archive
ARCHIVE_NAME="${ARCHIVE_NAME:-export.tar}"
ARCHIVE="${DEPLOY_DIR}/${ARCHIVE_NAME}"

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "::error::Archive not found: ${ARCHIVE}"
  exit 1
fi

echo "Target environment: ${TARGET_ENV}"
echo "API URL: ${API_URL}"
IMPORT_MODE="${IMPORT_MODE:-replace}"

echo "Archive: ${ARCHIVE}"
echo "Import mode: ${IMPORT_MODE}"
echo "Request URL: ${IMPORT_URL}"

# Build curl arguments for multipart/form-data upload
CURL_ARGS=(-s -w "\n%{http_code}" -X POST "${IMPORT_URL}" \
  -F "file=@${ARCHIVE}" \
  -F "importMode=${IMPORT_MODE}")

# Optionally attach vault file
VAULT_FILE="${DEPLOY_DIR}/vault.json"
if [[ -f "${VAULT_FILE}" ]]; then
  echo "Vault file found: ${VAULT_FILE}"
  CURL_ARGS+=(-F "vault=@${VAULT_FILE}")
fi

# Upload via POST multipart/form-data
RESPONSE=$(curl "${CURL_ARGS[@]}")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

echo "HTTP Status: ${HTTP_CODE}"
echo "Response: ${BODY}"

if [[ "${HTTP_CODE}" -ne 200 ]]; then
  echo "::error::Import API returned HTTP ${HTTP_CODE}: ${BODY}"
  exit 1
fi

# Check response for errors
CODE=$(echo "${BODY}" | jq -r '.code // empty')
if [[ -n "${CODE}" && "${CODE}" != "ok" ]]; then
  MESSAGE=$(echo "${BODY}" | jq -r '.message // empty')
  echo "::error::Import failed with code '${CODE}': ${MESSAGE}"
  exit 1
fi

# Extract recordId and diff from response
RECORD_ID=$(echo "${BODY}" | jq -r '.data.recordId // empty')
DIFF=$(echo "${BODY}" | jq -c '.data.diff // empty')

echo "Record ID: ${RECORD_ID}"
echo "Diff: ${DIFF}"

# Save response for downstream steps
SAFE_NAME="${RESOURCE_TYPE//\//_}"
echo "${BODY}" > "${DEPLOY_DIR}/${SAFE_NAME}-import-response.json"

# Output diff as changed_<resource_type> for downstream jobs
echo "changed_${SAFE_NAME}=${DIFF}" >> "${GITHUB_OUTPUT}"

echo "=== Import ${RESOURCE_TYPE} Complete ==="
