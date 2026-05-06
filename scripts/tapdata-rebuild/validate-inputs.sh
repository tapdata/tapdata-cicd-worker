#!/usr/bin/env bash
# Validate rebuild input parameters
# Required env vars: TARGET_ENV, TASK_NAMES, RESET_REASON, TAPDATA_URL
set -euo pipefail

VALID_ENVS=("dev" "sit" "lpt" "aat" "prod")

echo "=== Validating Rebuild Input Parameters ==="

# Validate TARGET_ENV
if [[ -z "${TARGET_ENV:-}" ]]; then
  echo "::error::TARGET_ENV is not set or empty"
  exit 1
fi

# Check TARGET_ENV is a valid environment
valid=false
for env in "${VALID_ENVS[@]}"; do
  if [[ "${TARGET_ENV}" == "${env}" ]]; then
    valid=true
    break
  fi
done

if [[ "${valid}" != "true" ]]; then
  echo "::error::TARGET_ENV '${TARGET_ENV}' is not a valid environment. Valid: ${VALID_ENVS[*]}"
  exit 1
fi

# Validate TASK_NAMES
if [[ -z "${TASK_NAMES:-}" ]]; then
  echo "::error::TASK_NAMES is not set or empty"
  exit 1
fi

# Validate RESET_REASON
if [[ -z "${RESET_REASON:-}" ]]; then
  echo "::error::RESET_REASON is not set or empty"
  exit 1
fi

# Validate TAPDATA_URL
if [[ -z "${TAPDATA_URL:-}" ]]; then
  echo "::error::TAPDATA_URL is not set or empty"
  exit 1
fi

echo "Target environment: ${TARGET_ENV}"
echo "Task names: ${TASK_NAMES}"
echo "Reset reason: ${RESET_REASON}"
echo "Need drop table: ${NEED_DROP_TABLE:-false}"
echo "Base URL: ${TAPDATA_URL}"
echo "=== Validation Passed ==="

