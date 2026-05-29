#!/usr/bin/env bash
# 扫描 {PROJECT}_tapdata_export 目录，收集本项目的任务名和 API 名
# 让回滚的 stop / unpublish / clean 严格限定在本项目，
# 避免空 TASK_NAMES/API_NAMES 触发 stop-tasks.sh 和 unpublish-apis.sh 的"全部"模式
#
# Required env vars: PROJECT
# Optional env vars: REPO_ROOT (兜底为脚本所在仓库根)
# Output (via GITHUB_OUTPUT):
#   task_names — 逗号分隔的任务名，可能为空（该项目无任务）
#   api_names  — 逗号分隔的 API 名，可能为空（该项目无 API）
#
# 目录约定（与 start-and-publish.sh / unpublish-apis.sh 保持一致）：
#   Task/*Task.json       — TapData 任务导出文件
#   Modules/*Module.json  — TapData API（Module）导出文件
set -euo pipefail

if [[ -z "${PROJECT:-}" ]]; then
  echo "::error::PROJECT is not set or empty"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
EXPORT_DIR="${REPO_ROOT}/${PROJECT}_tapdata_export"

echo "=== Collecting Resource Names from Export ==="
echo "Export dir: ${EXPORT_DIR}"

if [[ ! -d "${EXPORT_DIR}" ]]; then
  echo "::error::Export directory not found: ${EXPORT_DIR}"
  exit 1
fi

# ── 收集任务名 ──
# 与 start-and-publish.sh 的扫描方式保持一致：Task/*Task.json，取 .[0].json.name
TASK_NAMES=()
TASK_DIR="${EXPORT_DIR}/Task"
if [[ -d "${TASK_DIR}" ]]; then
  for f in "${TASK_DIR}"/*Task.json; do
    [[ -f "${f}" ]] || continue
    name=$(jq -r '.[0].json.name // empty' "${f}" 2>/dev/null || true)
    if [[ -n "${name}" ]]; then
      TASK_NAMES+=("${name}")
    fi
  done
fi

if [[ ${#TASK_NAMES[@]} -gt 0 ]]; then
  TASK_NAMES_CSV=$(IFS=','; echo "${TASK_NAMES[*]}")
else
  TASK_NAMES_CSV=""
fi

echo "Tasks found (${#TASK_NAMES[@]}): ${TASK_NAMES_CSV}"

# ── 收集 API 名 ──
# 约定：Modules/*Module.json，取 .[0].json.name（与 Module 的 name 字段对应，
# 也是 unpublish-apis.sh 用 where.name.$inq 过滤时所用字段）
API_NAMES=()
MODULES_DIR="${EXPORT_DIR}/Modules"
if [[ -d "${MODULES_DIR}" ]]; then
  for f in "${MODULES_DIR}"/*Module.json; do
    [[ -f "${f}" ]] || continue
    name=$(jq -r '.[0].json.name // empty' "${f}" 2>/dev/null || true)
    if [[ -n "${name}" ]]; then
      API_NAMES+=("${name}")
    fi
  done
fi

if [[ ${#API_NAMES[@]} -gt 0 ]]; then
  API_NAMES_CSV=$(IFS=','; echo "${API_NAMES[*]}")
else
  API_NAMES_CSV=""
fi

echo "APIs found (${#API_NAMES[@]}): ${API_NAMES_CSV}"

echo "task_names=${TASK_NAMES_CSV}" >> "${GITHUB_OUTPUT}"
echo "api_names=${API_NAMES_CSV}" >> "${GITHUB_OUTPUT}"
echo "=== Collect Resource Names Complete ==="
