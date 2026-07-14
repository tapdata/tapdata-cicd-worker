#!/usr/bin/env bash
# Compress all files in export directory into a tar archive
# Usage: compress-files.sh
# Required env vars: DEPLOY_DIR, PROJECT
# Optional env vars: ARCHIVE_NAME
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
EXPORT_DIR="${REPO_ROOT}/${PROJECT}_tapdata_export"

echo "=== Compressing Export Files ==="

# Validate inputs
if [[ -z "${DEPLOY_DIR:-}" ]]; then
  echo "::error::DEPLOY_DIR is not set or empty"
  exit 1
fi

if [[ -z "${PROJECT:-}" ]]; then
  echo "::error::PROJECT is not set or empty"
  exit 1
fi

if [[ ! -d "${EXPORT_DIR}" ]]; then
  echo "::error::Export directory not found: ${EXPORT_DIR}"
  exit 1
fi

# Create deploy directory
mkdir -p "${DEPLOY_DIR}"

ARCHIVE_NAME="${ARCHIVE_NAME:-export.tar}"

# Collect all files in export directory
FILES=()
while IFS= read -r f; do
  FILES+=("${f}")
done < <(find "${EXPORT_DIR}" -type f)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "::warning::No files found in ${EXPORT_DIR}"
  exit 0
fi

# Create tar archive
ARCHIVE="${DEPLOY_DIR}/${ARCHIVE_NAME}"
tar -cf "${ARCHIVE}" -C "${EXPORT_DIR}" "${FILES[@]/#${EXPORT_DIR}\//}"

VAULT_SOURCE="${EXPORT_DIR}/vault.json"
VAULT_TARGET="${DEPLOY_DIR}/vault.json"
if [[ -f "${VAULT_SOURCE}" ]]; then
  cp "${VAULT_SOURCE}" "${VAULT_TARGET}"
  echo "Vault copied: ${VAULT_TARGET}"
fi

echo "Archive created: ${ARCHIVE}"
echo "Files included: ${#FILES[@]}"
for f in "${FILES[@]}"; do
  echo "  - $(basename "${f}")"
done
echo "=== Compression Complete ==="

