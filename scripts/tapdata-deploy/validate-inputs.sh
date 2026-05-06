#!/usr/bin/env bash
# Validate deployment input parameters
# Required env vars: DEPLOYMENT_REF, TARGET_ENV, PROJECT
set -euo pipefail

VALID_ENVS=("dev" "sit" "lpt" "aat" "prod")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

echo "=== Validating Input Parameters ==="

# Validate DEPLOYMENT_REF
if [[ -z "${DEPLOYMENT_REF:-}" ]]; then
  echo "::error::DEPLOYMENT_REF is not set or empty"
  exit 1
fi

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

echo "DEPLOYMENT_REF: ${DEPLOYMENT_REF}"
echo "TARGET_ENV:     ${TARGET_ENV}"
echo "PROJECT:        ${PROJECT}"
echo "=== Validation Passed ==="
