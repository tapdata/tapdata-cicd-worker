#!/usr/bin/env bash
# Validate rollback input parameters
# Required env vars: TARGET_ENV, PROJECT, LAST_STABLE_TAG
set -euo pipefail

VALID_ENVS=("dev" "sit" "lpt" "aat" "prod")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

echo "=== Validating Rollback Input Parameters ==="

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
  echo "::error::TARGET_ENV '${TARGET_ENV}' is not valid. Allowed values: ${VALID_ENVS[*]}"
  exit 1
fi

# Validate LAST_STABLE_TAG is provided
if [[ -z "${LAST_STABLE_TAG:-}" ]]; then
  echo "::error::LAST_STABLE_TAG is not set or empty. A rollback tag must be provided."
  exit 1
fi

echo "LAST_STABLE_TAG: ${LAST_STABLE_TAG}"

# Validate PROJECT
if [[ -z "${PROJECT:-}" ]]; then
  echo "::error::PROJECT is not set or empty"
  exit 1
fi

EXPORT_DIR="${REPO_ROOT}/${PROJECT}_tapdata_export"
if [[ ! -d "${EXPORT_DIR}" ]]; then
  echo "::error::Export directory not found: ${EXPORT_DIR}. Please ensure '${PROJECT}_tapdata_export' exists in the repository root."
  exit 1
fi

echo "TARGET_ENV:      ${TARGET_ENV}"
echo "PROJECT:         ${PROJECT}"
echo "=== Validation Passed ==="

