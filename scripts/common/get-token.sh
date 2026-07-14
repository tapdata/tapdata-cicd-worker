#!/usr/bin/env bash
# Get TapData access token via authentication API
# Required env vars: TAPDATA_URL, TAPDATA_ACCESSCODE
# Output: tapdata_token (via GITHUB_OUTPUT)
set -euo pipefail

echo "=== Getting TapData Token ==="

# Validate required env vars
if [[ -z "${TAPDATA_URL:-}" ]]; then
  echo "::error::TAPDATA_URL is not set or empty"
  exit 1
fi

if [[ -z "${TAPDATA_ACCESSCODE:-}" ]]; then
  echo "::error::TAPDATA_ACCESSCODE is not set or empty"
  exit 1
fi

BASE_URL="${TAPDATA_URL}"

# Build full API URL
API_URL="${BASE_URL%/}/api/users/generatetoken"

echo "Target environment: ${TARGET_ENV}"
echo "API URL: ${API_URL}"

# Build request body
REQUEST_BODY=$(jq -n --arg code "${TAPDATA_ACCESSCODE}" '{accesscode: $code}')

# Call token API
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}" \
  -H "Content-Type: application/json" \
  -d "${REQUEST_BODY}")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 ]]; then
  echo "::error::Token API returned HTTP ${HTTP_CODE}: ${BODY}"
  exit 1
fi

# Check response code
CODE=$(echo "${BODY}" | jq -r '.code // empty')
if [[ -n "${CODE}" && "${CODE}" != "ok" ]]; then
  echo "::error::Token API returned code '${CODE}': ${BODY}"
  exit 1
fi

# Extract token from response
TOKEN=$(echo "${BODY}" | jq -r '.data.id // empty')

if [[ -z "${TOKEN}" ]]; then
  echo "::error::Failed to extract token from response: ${BODY}"
  exit 1
fi

# Set output for downstream jobs
echo "tapdata_token=${TOKEN}" >> "${GITHUB_OUTPUT}"
echo "=== Token Retrieved Successfully ==="

