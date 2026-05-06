#!/usr/bin/env bash
set -euo pipefail

# 检测 PROJECT 参数
# 输入环境变量：EVENT_NAME, INPUT_PROJECT, GITHUB_OUTPUT, GITHUB_ENV
# 逻辑：
#   - workflow_dispatch: 使用手动输入的 project
#   - push: 从 git diff 变更文件路径中提取 {project}_tapdata_export 前缀
#   - 检测失败：报错退出（避免静默使用错误的项目名）

if [[ "${EVENT_NAME}" == "workflow_dispatch" ]]; then
  PROJECT="${INPUT_PROJECT}"
elif [[ "${EVENT_NAME}" == "push" ]]; then
  PROJECT=$(git diff HEAD~1 --name-only | grep '_tapdata_export/' | head -1 | sed 's/_tapdata_export\/.*//' | sed 's|.*/||')
fi

if [[ -z "${PROJECT:-}" ]]; then
  echo "ERROR: cannot detect PROJECT (no *_tapdata_export/ paths in diff). Pass it explicitly via workflow_dispatch input." >&2
  exit 1
fi

echo "Detected PROJECT: $PROJECT"
echo "project=$PROJECT" >> "$GITHUB_OUTPUT"
echo "PROJECT=$PROJECT" >> "$GITHUB_ENV"
