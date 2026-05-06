#!/usr/bin/env bash
# Consolidate preview markdown files into GITHUB_STEP_SUMMARY
# Usage: consolidate-previews.sh <file1> <file2> ...
# Files are written in the order provided (pass newest first for reverse-chronological display)
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "::error::Usage: consolidate-previews.sh <file1> <file2> ..."
  exit 1
fi

echo "# Deployment Summary" >> "${GITHUB_STEP_SUMMARY}"
echo "" >> "${GITHUB_STEP_SUMMARY}"

for file in "$@"; do
  if [[ -f "${file}" ]]; then
    cat "${file}" >> "${GITHUB_STEP_SUMMARY}"
    echo "" >> "${GITHUB_STEP_SUMMARY}"
  else
    echo "::warning::Preview file not found: ${file}"
  fi
done

echo "=== Deployment summary written to GITHUB_STEP_SUMMARY ==="
