#!/usr/bin/env bash
# Validate that the provided rollback tag exists in the repository
# Single-repo mode: checks local git tags
# Multi-repo mode:  checks caller_repo tags via GitHub API (requires GH_TOKEN + CALLER_REPO)
# Required env vars: LAST_STABLE_TAG
# Optional env vars: CALLER_REPO, GH_TOKEN
# Output: last_stable_tag (via GITHUB_OUTPUT)
set -euo pipefail

echo "=== Validating Rollback Tag ==="

if [[ -z "${LAST_STABLE_TAG:-}" ]]; then
  echo "::error::LAST_STABLE_TAG is not set or empty. A rollback tag must be provided."
  exit 1
fi

if [[ -n "${CALLER_REPO:-}" ]]; then
  # ── 多租户模式：通过 GitHub API 验证 tag 是否存在于租户仓库 ──
  echo "Multi-repo mode: validating tag '${LAST_STABLE_TAG}' in repo '${CALLER_REPO}' via GitHub API..."

  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is required for multi-repo tag validation."
    exit 1
  fi

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${CALLER_REPO}/git/ref/tags/${LAST_STABLE_TAG}")

  if [[ "${HTTP_CODE}" -eq 200 ]]; then
    echo "Tag '${LAST_STABLE_TAG}' exists in '${CALLER_REPO}', using it for rollback."
  elif [[ "${HTTP_CODE}" -eq 404 ]]; then
    echo "::error::Tag '${LAST_STABLE_TAG}' does not exist in repo '${CALLER_REPO}'."
    exit 1
  else
    echo "::error::Unexpected HTTP ${HTTP_CODE} when checking tag '${LAST_STABLE_TAG}' in '${CALLER_REPO}'."
    exit 1
  fi
else
  # ── 单仓库模式：直接检查本地 git 仓库 ──
  echo "Single-repo mode: validating tag '${LAST_STABLE_TAG}' in local git repository..."

  if ! git rev-parse "refs/tags/${LAST_STABLE_TAG}" >/dev/null 2>&1; then
    echo "::error::Tag '${LAST_STABLE_TAG}' does not exist in the repository."
    exit 1
  fi

  echo "Tag '${LAST_STABLE_TAG}' exists, using it for rollback."
fi

echo "last_stable_tag=${LAST_STABLE_TAG}" >> "${GITHUB_OUTPUT}"
echo "=== Tag Validation Complete ==="
