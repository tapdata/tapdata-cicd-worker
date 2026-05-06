#!/usr/bin/env bash
# Check that the tapdata_export directory exists and is not empty.
# Required env vars: EXPORT_DIR
# On failure: writes error annotation + GitHub Step Summary, then exits 1.
set -euo pipefail

if [[ -z "${EXPORT_DIR:-}" ]]; then
  echo "::error::EXPORT_DIR is not set or empty"
  exit 1
fi

PROJECT_EXPORT="$(basename "$EXPORT_DIR")"

if [[ ! -d "$EXPORT_DIR" ]]; then
  echo "::error::tapdata_export directory not found: $EXPORT_DIR"
  {
    echo "## ❌ Workflow Aborted"
    echo ""
    echo "Export directory \`${PROJECT_EXPORT}/\` not found. Please check:"
    echo "1. Is the project name correct?"
    echo "2. Has the directory been committed to the repository?"
  } >> "$GITHUB_STEP_SUMMARY"
  exit 1
fi

FILE_COUNT=$(find "$EXPORT_DIR" -type f | wc -l | tr -d ' ')
if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "::error::tapdata_export directory is empty: $EXPORT_DIR"
  {
    echo "## ❌ Workflow Aborted"
    echo ""
    echo "Export directory \`${PROJECT_EXPORT}/\` exists but contains no files."
  } >> "$GITHUB_STEP_SUMMARY"
  exit 1
fi

echo "✅ Export directory found: $EXPORT_DIR ($FILE_COUNT files)"
